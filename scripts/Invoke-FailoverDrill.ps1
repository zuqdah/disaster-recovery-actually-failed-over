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
$failoverStartedAt = [datetime]::UtcNow
Write-Information "Commanding failover to $SecondaryServer."
az sql failover-group set-primary --name $FailoverGroup --resource-group $SecondaryResourceGroup `
    --server $SecondaryServer --no-wait 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'The failover command was rejected.' }

# Keep writing. The first failure is the failure: it is the moment the
# application stopped being able to serve, which is where the recovery time
# objective is written from. The failover command being accepted is not that
# moment, and the two can be many seconds apart.
$failedAt = $null
$restoredAt = $null
$failoverCompletedAt = $null
$outageDeadline = [datetime]::UtcNow.AddMinutes(10)
$nextRoleCheck = [datetime]::UtcNow

while ([datetime]::UtcNow -lt $outageDeadline) {
    # The role is polled on a timer rather than every iteration, because the
    # control plane call is far slower than a write and would otherwise become
    # the thing being measured.
    if ($null -eq $failoverCompletedAt -and [datetime]::UtcNow -ge $nextRoleCheck) {
        if ((Get-ReplicationRole -GroupName $FailoverGroup -ResourceGroup $SecondaryResourceGroup -Server $SecondaryServer) -eq 'Primary') {
            $failoverCompletedAt = [datetime]::UtcNow
        }
        $nextRoleCheck = [datetime]::UtcNow.AddSeconds(5)
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

# No write failed at all. The outage was shorter than the gap between two
# writes, so the honest reading is an observed outage of zero rather than a
# missing measurement -- recorded alongside the rate, because zero observed at
# one write per second says nothing about a system taking hundreds.
$observedOutage = $null -ne $failedAt
if (-not $observedOutage) {
    Write-Information '  no write ever failed: the outage was below this drill write rate resolution.'
    $failedAt = $restoredAt
}

Write-Information 'Failover complete. Reading what survived.'
$token = Get-SqlToken
$surviving = @(Invoke-Sql -Endpoint $Listener -DatabaseName $Database -Token $token -Query 'SELECT seq FROM dbo.drill_writes ORDER BY seq;' | ForEach-Object { [int]$_.seq })
$servingServer = (Invoke-Sql -Endpoint $Listener -DatabaseName $Database -Token $token -Query 'SELECT @@SERVERNAME AS s;').s

# --------------------------------------------------------------- measurement
$plan = [System.IO.File]::ReadAllText($PlanPath) | ConvertFrom-Json

$timeline = [pscustomobject]@{
    FailedAt            = $failedAt
    DetectedAt          = $failedAt
    FailoverStartedAt   = $failoverStartedAt
    FailoverCompletedAt = $failoverCompletedAt
    ServiceRestoredAt   = $restoredAt
}

$recovery = Measure-RecoveryObjective -Timeline $timeline
$window = ($restoredAt - $writeStarted).TotalSeconds
$dataLoss = Measure-DataLoss -Acknowledged $acknowledged.ToArray() -Surviving $surviving -WindowSeconds $window
$grade = Compare-ObjectiveToMeasurement -Objective $plan.objectives -Recovery $recovery -DataLoss $dataLoss

# ------------------------------------------------------------- failback phase
# A plan that only goes one way leaves the estate in a worse position than it
# started, running unprotected in the region it fled to. Failing back is part
# of the drill, not an afterthought.
Write-Information "Failing back to $PrimaryServer."
$failbackStartedAt = [datetime]::UtcNow
az sql failover-group set-primary --name $FailoverGroup --resource-group $PrimaryResourceGroup `
    --server $PrimaryServer 2>&1 | Out-Null
$failbackOk = $LASTEXITCODE -eq 0

$finalRole = Get-ReplicationRole -GroupName $FailoverGroup -ResourceGroup $PrimaryResourceGroup -Server $PrimaryServer
$failbackSeconds = ([datetime]::UtcNow - $failbackStartedAt).TotalSeconds

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
    recovery  = $recovery
    dataLoss  = $dataLoss
    grade     = $grade
    failback  = [pscustomobject]@{
        succeeded      = $failbackOk
        seconds        = [math]::Round($failbackSeconds, 1)
        finalRole      = $finalRole
        servedFromDuringDrill = $servingServer
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
