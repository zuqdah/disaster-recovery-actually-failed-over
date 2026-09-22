#requires -Version 7.0

<#
    .SYNOPSIS
        Fails a database over for real, measures what it cost, and grades the
        result against the objectives the plan claims.
    .DESCRIPTION
        Everything connects through the failover group listener and never to a
        server directly. That is the point: if the drill reconnects by editing a
        connection string, it has proved the replica works and proved nothing
        about the recovery.

        A writer commits numbered rows continuously while the failover runs, so
        the recovery point can be measured from what the old primary actually
        acknowledged rather than inferred from a clock. The failure time is the
        first write that fails, not the moment the failover was commanded --
        those differ, and using the second one is how a drill reports a recovery
        time that no real incident would ever produce.
    .PARAMETER Listener
        The failover group endpoint.
    .PARAMETER Database
        Database inside the group.
    .PARAMETER FailoverGroup
        Name of the failover group.
    .PARAMETER PrimaryServer
        Server that is primary at the start, and primary again at the end.
    .PARAMETER SecondaryServer
        Server promoted during the drill.
    .PARAMETER PrimaryResourceGroup
        Resource group of the primary server.
    .PARAMETER SecondaryResourceGroup
        Resource group of the secondary server.
    .PARAMETER PlanPath
        The recovery plan, carrying the objectives to grade against.
    .PARAMETER WriteSeconds
        How long to write before commanding the failover.
    .PARAMETER ReportPath
        Where to write the JSON report.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Listener,
    [Parameter(Mandatory)][string]$Database,
    [Parameter(Mandatory)][string]$FailoverGroup,
    [Parameter(Mandatory)][string]$PrimaryServer,
    [Parameter(Mandatory)][string]$SecondaryServer,
    [Parameter(Mandatory)][string]$PrimaryResourceGroup,
    [Parameter(Mandatory)][string]$SecondaryResourceGroup,
    [string]$PlanPath = 'recovery-plan.json',
    [int]$WriteSeconds = 45,
    [string]$ReportPath = 'drill-report.json'
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
Set-StrictMode -Version Latest

Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'module', 'Recovery', 'Recovery.psm1')) -Force -ErrorAction Stop
Import-Module SqlServer -ErrorAction Stop

function Get-SqlToken {
    $raw = az account get-access-token --resource 'https://database.windows.net/' -o json
    if ($LASTEXITCODE -ne 0) { throw 'Could not obtain a token for Azure SQL.' }
    $token = ($raw | ConvertFrom-Json).accessToken
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'The token response carried no access token.' }
    return $token
}

# These take everything they use rather than reaching into the parent scope.
# A helper that captures the endpoint it connects to is a helper that will
# happily keep talking to the old one after somebody adds a second.
function Invoke-Sql {
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$Token,
        [int]$TimeoutSeconds = 15
    )

    Invoke-Sqlcmd -ServerInstance $Endpoint -Database $DatabaseName -AccessToken $Token `
        -Query $Query -ConnectionTimeout $TimeoutSeconds -QueryTimeout $TimeoutSeconds -ErrorAction Stop
}

function Get-ReplicationRole {
    param(
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$Server
    )
    az sql failover-group show --name $GroupName --resource-group $ResourceGroup --server $Server `
        --query "replicationRole" -o tsv 2>$null
}

$token = Get-SqlToken

Write-Information "Preparing the drill table through the listener $Listener."
Invoke-Sql -Endpoint $Listener -DatabaseName $Database -Token $token -Query @'
IF OBJECT_ID('dbo.drill_writes', 'U') IS NOT NULL DROP TABLE dbo.drill_writes;
CREATE TABLE dbo.drill_writes (
    seq         INT           NOT NULL PRIMARY KEY,
    written_at  DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME()
);
'@

$startingRole = Get-ReplicationRole -GroupName $FailoverGroup -ResourceGroup $PrimaryResourceGroup -Server $PrimaryServer
if ($startingRole -ne 'Primary') {
    throw "The drill expects $PrimaryServer to be primary at the start, but it reports '$startingRole'."
}

# ---------------------------------------------------------------- write phase
# Every acknowledged sequence number is recorded with the time the server
# confirmed it. Those acknowledgements are the only sound basis for a recovery
# point measurement later.
$acknowledged = [System.Collections.Generic.List[int]]::new()
$seq = 0
$writeStarted = [datetime]::UtcNow
$deadline = $writeStarted.AddSeconds($WriteSeconds)

while ([datetime]::UtcNow -lt $deadline) {
    $seq++
    Invoke-Sql -Endpoint $Listener -DatabaseName $Database -Token $token -Query "INSERT INTO dbo.drill_writes (seq) VALUES ($seq);"
    $acknowledged.Add($seq)
}
Write-Information "  $($acknowledged.Count) writes acknowledged before the failover was commanded."

# ------------------------------------------------------------- failover phase
# The ARM call rather than `az sql failover-group set-primary`, because that
# command blocks until the failover finishes and has no --no-wait. Waiting for
# it would mean nothing was writing during the switch, and the outage this
# drill exists to measure would happen with nobody watching. The REST call
# returns 202 Accepted straight away and the swap proceeds behind it.
$subscriptionId = az account show --query id -o tsv
if ([string]::IsNullOrWhiteSpace($subscriptionId)) { throw 'Could not determine the subscription.' }

$failoverUrl = "https://management.azure.com/subscriptions/$subscriptionId" +
    "/resourceGroups/$SecondaryResourceGroup/providers/Microsoft.Sql/servers/$SecondaryServer" +
    "/failoverGroups/$FailoverGroup/failover?api-version=2021-11-01"

$failoverStartedAt = [datetime]::UtcNow
Write-Information "Commanding failover to $SecondaryServer."
$failoverResponse = az rest --method POST --url $failoverUrl 2>&1
if ($LASTEXITCODE -ne 0) {
    # The reason travels with the failure. An earlier version discarded this
    # output, and the run reported only that the command had been rejected --
    # which is the least useful true thing it could have said.
    throw "The failover command was rejected: $failoverResponse"
}

# Keep writing. The first failure is the failure: it is the moment the
# application stopped being able to serve, which is where the recovery time
# objective is written from. The failover command being accepted is not that
# moment, and the two can be many seconds apart.
$failedAt = $null
$restoredAt = $null
$failoverCompletedAt = $null
$outageDeadline = [datetime]::UtcNow.AddMinutes(10)
# Every phase timed by polling the control plane is only accurate to this
# interval, so it travels into the report rather than being left for the
# reader to assume it was exact.
$rolePollSeconds = 5
$nextRoleCheck = [datetime]::UtcNow

while ([datetime]::UtcNow -lt $outageDeadline) {
    # The role is polled on a timer rather than every iteration, because the
    # control plane call is far slower than a write and would otherwise become
    # the thing being measured.
    if ($null -eq $failoverCompletedAt -and [datetime]::UtcNow -ge $nextRoleCheck) {
        if ((Get-ReplicationRole -GroupName $FailoverGroup -ResourceGroup $SecondaryResourceGroup -Server $SecondaryServer) -eq 'Primary') {
            $failoverCompletedAt = [datetime]::UtcNow
        }
        $nextRoleCheck = [datetime]::UtcNow.AddSeconds($rolePollSeconds)
    }

    $seq++
    try {
        Invoke-Sql -Endpoint $Listener -DatabaseName $Database -Token $token -Query "INSERT INTO dbo.drill_writes (seq) VALUES ($seq);" -TimeoutSeconds 10
        $acknowledged.Add($seq)

        # Done once a write has succeeded and the swap is real. Waiting for a
        # failed write would hang forever on a failover clean enough not to
        # produce one, which is the best possible outcome and must not be
        # mistaken for the drill never recovering.
        if ($null -ne $failedAt -or $null -ne $failoverCompletedAt) {
            $restoredAt = [datetime]::UtcNow
            break
        }
    }
    catch {
        if ($null -eq $failedAt) {
            $failedAt = [datetime]::UtcNow
            Write-Information "  writes began failing at $($failedAt.ToString('o'))"
        }
        # The token can outlive the connection but not the outage; refresh it so
        # a recovered service is not mistaken for a still-broken one.
        $token = Get-SqlToken
        Start-Sleep -Milliseconds 500
    }
}

if ($null -eq $restoredAt) {
    throw 'Writes never recovered within ten minutes. The drill could not measure a recovery.'
}

# The control plane can still be catching up after writes resume.
$roleDeadline = [datetime]::UtcNow.AddMinutes(5)
while ($null -eq $failoverCompletedAt -and [datetime]::UtcNow -lt $roleDeadline) {
    if ((Get-ReplicationRole -GroupName $FailoverGroup -ResourceGroup $SecondaryResourceGroup -Server $SecondaryServer) -eq 'Primary') {
        $failoverCompletedAt = [datetime]::UtcNow
    }
    else { Start-Sleep -Seconds 5 }
}
if ($null -eq $failoverCompletedAt) { throw 'The failover group never reported the secondary as primary.' }

# No write failed at all. An earlier version substituted the restore time for
# the failure so there was always a number, which put the failure after the
# failover command and produced a negative decision interval in the report --
# a drill flattering itself with an impossible measurement, which is the exact
# failure this lab exists to catch. The absence is now carried through as an
# absence.
$observedOutage = $null -ne $failedAt
if (-not $observedOutage) {
    Write-Information '  no write ever failed: the outage was shorter than the gap between two writes.'
}

Write-Information 'Failover complete. Reading what survived.'
$token = Get-SqlToken
$surviving = @(Invoke-Sql -Endpoint $Listener -DatabaseName $Database -Token $token -Query 'SELECT seq FROM dbo.drill_writes ORDER BY seq;' | ForEach-Object { [int]$_.seq })

# Not @@SERVERNAME. On a geo-replicated database it reported the original
# server after a failover the control plane had already confirmed, so it is
# either lagging or means something other than which replica is serving -- and
# a claim resting on an identifier whose meaning is unclear is not a claim.
#
# Updateability is unambiguous: a geo-secondary is READ_ONLY, so READ_WRITE
# means this connection is being served by the primary replica. Combined with
# the control plane reporting the secondary region as Primary, that is what
# establishes the listener followed the failover.
$updateability = (Invoke-Sql -Endpoint $Listener -DatabaseName $Database -Token $token `
    -Query "SELECT CAST(DATABASEPROPERTYEX(DB_NAME(),'Updateability') AS nvarchar(64)) AS u;").u
Write-Information "  the listener is serving a $updateability replica"
if ($updateability -ne 'READ_WRITE') {
    throw "After failover the listener is serving a $updateability replica. The promotion did not carry the endpoint with it."
}

# --------------------------------------------------------------- measurement
$plan = [System.IO.File]::ReadAllText($PlanPath) | ConvertFrom-Json

$timeline = [pscustomobject]@{
    FailedAt            = $failedAt
    DetectedAt          = $failedAt
    FailoverStartedAt   = $failoverStartedAt
    FailoverCompletedAt = $failoverCompletedAt
    ServiceRestoredAt   = $restoredAt
}

$recovery = Measure-RecoveryObjective -Timeline $timeline -NoOutageObserved:(-not $observedOutage)
$window = ($restoredAt - $writeStarted).TotalSeconds
$dataLoss = Measure-DataLoss -Acknowledged $acknowledged.ToArray() -Surviving $surviving -WindowSeconds $window
$grade = Compare-ObjectiveToMeasurement -Objective $plan.objectives -Recovery $recovery -DataLoss $dataLoss

# ------------------------------------------------------------- failback phase
# A plan that only goes one way leaves the estate in a worse position than it
# started, running unprotected in the region it fled to. Failing back is part
# of the drill, not an afterthought.
Write-Information "Failing back to $PrimaryServer."
# Blocking here on purpose. Nothing is being timed on the way back, so the
# simpler command is the right one -- but its output is kept, because a silent
# failback failure leaves the estate in the region it fled to.
$failbackStartedAt = [datetime]::UtcNow
$failbackOutput = az sql failover-group set-primary --name $FailoverGroup `
    --resource-group $PrimaryResourceGroup --server $PrimaryServer 2>&1
$failbackOk = $LASTEXITCODE -eq 0
if (-not $failbackOk) { Write-Information "  failback error: $failbackOutput" }

# How long the command took is not how long the failback took. The command
# returned in under two seconds against seven for the forward failover, which
# says more about when the CLI stops waiting than about the estate. The role
# flipping back is the thing worth timing, so it is polled the same way the
# failover was and the two numbers are comparable.
$finalRole = $null
$failbackDeadline = [datetime]::UtcNow.AddMinutes(5)
while ([datetime]::UtcNow -lt $failbackDeadline) {
    $finalRole = Get-ReplicationRole -GroupName $FailoverGroup -ResourceGroup $PrimaryResourceGroup -Server $PrimaryServer
    if ($finalRole -eq 'Primary') { break }
    Start-Sleep -Seconds $rolePollSeconds
}
$failbackSeconds = ([datetime]::UtcNow - $failbackStartedAt).TotalSeconds
$failbackOk = $failbackOk -and $finalRole -eq 'Primary'

# ------------------------------------------------------------------- report
$report = [pscustomobject]@{
    drilledAt = $writeStarted.ToString('o')
    listener  = $Listener
    objectives = $plan.objectives
    timeline  = [pscustomobject]@{
        failedAt            = if ($failedAt) { $failedAt.ToString('o') } else { $null }
        failoverStartedAt   = $failoverStartedAt.ToString('o')
        failoverCompletedAt = $failoverCompletedAt.ToString('o')
        serviceRestoredAt   = $restoredAt.ToString('o')
    }
    observedOutage = $observedOutage
    rolePollSeconds = $rolePollSeconds
    recovery  = $recovery
    dataLoss  = $dataLoss
    grade     = $grade
    failback  = [pscustomobject]@{
        succeeded      = $failbackOk
        seconds        = [math]::Round($failbackSeconds, 1)
        finalRole      = $finalRole
        listenerUpdateability   = $updateability
    }
}

[System.IO.File]::WriteAllText($ReportPath, ($report | ConvertTo-Json -Depth 8),
    (New-Object System.Text.UTF8Encoding($false)))

Write-Information ''
Write-Information '--- recovery time ---'
Write-Information ("  {0:N1} s, measured from {1}" -f $recovery.RecoveryTimeSeconds, $recovery.MeasuredFrom)
foreach ($k in $recovery.Breakdown.Keys) {
    Write-Information ("    {0,-12} {1,7:N1} s" -f $k, $recovery.Breakdown[$k])
}
if ($recovery.Caveat) { Write-Information "  caveat: $($recovery.Caveat)" }

Write-Information ''
Write-Information '--- recovery point ---'
Write-Information "  $($dataLoss.Verdict): $($dataLoss.Detail)"

Write-Information ''
Write-Information '--- against the objectives ---'
Write-Information "  RTO  $(if ($grade.RtoMet) { 'met ' } else { 'MISSED' })  $($grade.RtoDetail)"
Write-Information "  RPO  $(if ($grade.RpoMet) { 'met ' } else { 'MISSED' })  $($grade.RpoDetail)"
Write-Information "  failback: $(if ($failbackOk) { "succeeded in $([math]::Round($failbackSeconds,1)) s, $PrimaryServer is $finalRole again" } else { 'FAILED' })"

if ($env:GITHUB_STEP_SUMMARY) {
    @(
        '### Failover drill'
        ''
        '| | |'
        '|---|---|'
        "| Recovery time | **$([math]::Round($recovery.RecoveryTimeSeconds,1)) s** against a $($plan.objectives.RtoSeconds) s objective |"
        "| Measured from | $($recovery.MeasuredFrom) |"
        "| Recovery point | $($dataLoss.Verdict) - $($dataLoss.AcknowledgedCount) writes at $($dataLoss.WritesPerSecond)/s |"
        "| Failback | $(if ($failbackOk) { "$([math]::Round($failbackSeconds,1)) s" } else { 'failed' }) |"
        ''
        '| Phase | Seconds |'
        '|---|---|'
    ) + @($recovery.Breakdown.Keys | ForEach-Object { "| $_ | $([math]::Round($recovery.Breakdown[$_],1)) |" }) |
        Out-File $env:GITHUB_STEP_SUMMARY -Append
}

if (-not $failbackOk) { throw "Failback failed; $PrimaryServer reports '$finalRole'." }
if (-not $grade.Passed) { throw "The drill missed its objectives. RTO: $($grade.RtoDetail) RPO: $($grade.RpoDetail)" }

Write-Information ''
Write-Information 'The plan holds: recovery and recovery point both inside their objectives, and the estate is back where it started.'
