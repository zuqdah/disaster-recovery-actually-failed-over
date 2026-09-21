#requires -Version 7.0

Set-StrictMode -Version Latest

function Get-OptionalProperty {
    <#
        .SYNOPSIS
            Reads a property that may be absent, without tripping StrictMode.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Measure-RecoveryObjective {
    <#
        .SYNOPSIS
            Turns a drill timeline into the two numbers a DR plan is judged on.
        .DESCRIPTION
            Recovery time is measured from the failure, not from the moment
            somebody decided to act on it. This is the single most common way a
            DR report flatters itself: the clock starts when the failover command
            is issued, which silently excludes detection and decision time. In a
            real incident those are usually most of the outage, and they are the
            part a runbook can actually improve.

            So the timeline must carry FailedAt. If it only carries the moment of
            the command, the result is still returned -- but marked as measuring
            a shorter interval than the objective is written against, rather than
            quietly reported as the recovery time.
        .PARAMETER Timeline
            An object carrying FailedAt, DetectedAt, FailoverStartedAt,
            FailoverCompletedAt and ServiceRestoredAt.
        .OUTPUTS
            The measured intervals, in seconds, and what each one covers.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Timeline
    )

    $failedAt = Get-OptionalProperty $Timeline 'FailedAt'
    $detectedAt = Get-OptionalProperty $Timeline 'DetectedAt'
    $startedAt = Get-OptionalProperty $Timeline 'FailoverStartedAt'
    $completedAt = Get-OptionalProperty $Timeline 'FailoverCompletedAt'
    $restoredAt = Get-OptionalProperty $Timeline 'ServiceRestoredAt'

    if ($null -eq $restoredAt) {
        throw 'The timeline has no ServiceRestoredAt, so there is no recovery to measure.'
    }

    # Service restored is the end of the outage, not failover completed. The
    # replica being writable does not help anyone until the application is
    # actually serving from it.
    $endOfOutage = [datetime]$restoredAt

    $caveat = $null
    $measuredFrom = $null
    if ($null -ne $failedAt) {
        $start = [datetime]$failedAt
        $measuredFrom = 'failure'
    }
    elseif ($null -ne $detectedAt) {
        $start = [datetime]$detectedAt
        $measuredFrom = 'detection'
        $caveat = 'The timeline has no FailedAt, so this measures from detection and excludes however long the failure went unnoticed. It is not comparable to an RTO written against the failure.'
    }
    else {
        $start = [datetime]$startedAt
        $measuredFrom = 'the failover command'
        $caveat = 'The timeline records only when failover was commanded, so this excludes detection and decision time entirely. In a real incident that is usually most of the outage.'
    }

    $breakdown = [ordered]@{}
    if ($null -ne $failedAt -and $null -ne $detectedAt) {
        $breakdown['detection'] = ([datetime]$detectedAt - [datetime]$failedAt).TotalSeconds
    }
    if ($null -ne $detectedAt -and $null -ne $startedAt) {
        $breakdown['decision'] = ([datetime]$startedAt - [datetime]$detectedAt).TotalSeconds
    }
    if ($null -ne $startedAt -and $null -ne $completedAt) {
        $breakdown['failover'] = ([datetime]$completedAt - [datetime]$startedAt).TotalSeconds
    }
    if ($null -ne $completedAt) {
        $breakdown['reconnect'] = ($endOfOutage - [datetime]$completedAt).TotalSeconds
    }

    [pscustomobject]@{
        RecoveryTimeSeconds = ($endOfOutage - $start).TotalSeconds
        MeasuredFrom        = $measuredFrom
        Breakdown           = $breakdown
        Caveat              = $caveat
    }
}

function Measure-DataLoss {
    <#
        .SYNOPSIS
            Measures what was actually lost, by comparing writes rather than clocks.
        .DESCRIPTION
            Recovery point is not "how long since the last backup". It is the
            newest thing the primary told a client it had committed, which did not
            survive the failover. Measuring it therefore needs two facts a clock
            cannot supply: what the old primary acknowledged, and what the new
            primary actually has.

            The important subtlety is the negative result. Observing no loss does
            not establish that no loss is possible -- it can equally mean the
            drill did not write fast enough to catch any. A run that committed
            four transactions in a minute has proved almost nothing about a
            system taking hundreds a second. So the write rate travels with the
            verdict, and a drill with too few writes says it was inconclusive
            rather than clean.
        .PARAMETER Acknowledged
            Sequence numbers the old primary confirmed as committed, in order.
        .PARAMETER Surviving
            Sequence numbers present on the new primary after failover.
        .PARAMETER WindowSeconds
            How long writes were running, used to report the rate the result rests on.
        .PARAMETER MinimumWrites
            Below this many acknowledged writes the result is called inconclusive.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$Acknowledged,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$Surviving,
        [Parameter(Mandatory)][double]$WindowSeconds,
        [int]$MinimumWrites = 30
    )

    $survivingSet = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($item in $Surviving) { [void]$survivingSet.Add($item) }

    $lost = @($Acknowledged | Where-Object { -not $survivingSet.Contains($_) })
    $rate = if ($WindowSeconds -gt 0) { [math]::Round($Acknowledged.Count / $WindowSeconds, 2) } else { 0 }

    # A write that survives while an earlier one does not is not a recovery
    # point problem, it is a correctness problem, and it should never be
    # reported as "no data loss" just because the count came out low.
    $outOfOrder = $false
    if ($lost.Count -and $Surviving.Count) {
        $highestLost = ($lost | Measure-Object -Maximum).Maximum
        $highestSurviving = ($Surviving | Measure-Object -Maximum).Maximum
        $outOfOrder = $highestSurviving -gt $highestLost
    }

    $conclusive = $Acknowledged.Count -ge $MinimumWrites

    $verdict = if (-not $conclusive) { 'Inconclusive' }
        elseif ($outOfOrder) { 'OutOfOrderLoss' }
        elseif ($lost.Count -eq 0) { 'NoLossObserved' }
        else { 'DataLost' }

    $detail = switch ($verdict) {
        'Inconclusive' {
            "Only $($Acknowledged.Count) acknowledged write(s) over $WindowSeconds s. That is too few to conclude anything about data loss; it is not a clean result."
        }
        'OutOfOrderLoss' {
            "$($lost.Count) acknowledged write(s) are missing while later ones survived. That is not a recovery point gap, it is replication applying writes out of order, and it needs explaining before any RPO claim."
        }
        'NoLossObserved' {
            "No acknowledged write was lost, at $rate write(s)/second over $WindowSeconds s. This is evidence of no loss at that rate, not proof that loss is impossible at a higher one."
        }
        default {
            "$($lost.Count) acknowledged write(s) did not survive, at $rate write(s)/second."
        }
    }

    [pscustomobject]@{
        Verdict          = $verdict
        LostCount        = $lost.Count
        LostSequences    = $lost
        AcknowledgedCount = $Acknowledged.Count
        SurvivingCount   = $Surviving.Count
        WritesPerSecond  = $rate
        Conclusive       = $conclusive
        Detail           = $detail
    }
}

function Compare-ObjectiveToMeasurement {
    <#
        .SYNOPSIS
            Grades a drill against the objectives it was written to meet.
        .DESCRIPTION
            An objective that was never measured is not a pass. Neither is one
            measured from the wrong starting point, and neither is a data loss
            result the drill was too small to support -- all three come back as
            failures with the reason attached, because a DR report whose worst
            outcome is "we could not tell" teaches its readers to stop reading.
        .PARAMETER Objective
            The stated objectives: RtoSeconds, RpoSeconds and why each was chosen.
        .PARAMETER Recovery
            Output from Measure-RecoveryObjective.
        .PARAMETER DataLoss
            Output from Measure-DataLoss.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Objective,
        [Parameter(Mandatory)][object]$Recovery,
        [Parameter(Mandatory)][object]$DataLoss
    )

    $statedRto = [double](Get-OptionalProperty $Objective 'RtoSeconds')
    $measuredRto = [double](Get-OptionalProperty $Recovery 'RecoveryTimeSeconds')
    $measuredFrom = [string](Get-OptionalProperty $Recovery 'MeasuredFrom')

    $rtoMet = $measuredRto -le $statedRto
    $rtoDetail = if (-not $rtoMet) {
        "Recovery took $([math]::Round($measuredRto, 1)) s against an objective of $statedRto s."
    }
    elseif ($measuredFrom -ne 'failure') {
        # Comfortably inside an objective measured from the wrong place is not
        # the same as meeting it.
        $rtoMet = $false
        "Recovery took $([math]::Round($measuredRto, 1)) s, inside the $statedRto s objective, but measured from $measuredFrom rather than from the failure. The comparison is not valid."
    }
    else {
        "Recovery took $([math]::Round($measuredRto, 1)) s against an objective of $statedRto s, measured from the failure."
    }

    $lossVerdict = [string](Get-OptionalProperty $DataLoss 'Verdict')
    $rpoMet = $lossVerdict -eq 'NoLossObserved'
    $rpoDetail = [string](Get-OptionalProperty $DataLoss 'Detail')

    # A non-zero recovery point objective permits some loss, so losing writes is
    # only a failure when it exceeds what was declared acceptable.
    $statedRpo = [double](Get-OptionalProperty $Objective 'RpoSeconds')
    if ($lossVerdict -eq 'DataLost' -and $statedRpo -gt 0) {
        $rate = [double](Get-OptionalProperty $DataLoss 'WritesPerSecond')
        if ($rate -gt 0) {
            $lostSeconds = [double](Get-OptionalProperty $DataLoss 'LostCount') / $rate
            $rpoMet = $lostSeconds -le $statedRpo
            $rpoDetail = "$((Get-OptionalProperty $DataLoss 'LostCount')) write(s) lost, about $([math]::Round($lostSeconds, 1)) s of work at the observed rate, against an objective of $statedRpo s."
        }
    }

    [pscustomobject]@{
        RtoMet     = $rtoMet
        RtoDetail  = $rtoDetail
        RpoMet     = $rpoMet
        RpoDetail  = $rpoDetail
        Passed     = ($rtoMet -and $rpoMet)
    }
}

function Test-RunbookStep {
    <#
        .SYNOPSIS
            Checks a runbook can be followed by somebody who did not write it.
        .DESCRIPTION
            The test is not whether the steps are correct -- no static check can
            know that. It is whether each one can be carried out and confirmed by
            a stranger at three in the morning. A step with an action but no way
            to tell whether it worked is where drills quietly diverge from
            incidents: the author knows what success looks like and never wrote
            it down.

            A step whose action is to contact a named person is called out
            separately. It is not wrong -- some decisions need a human -- but a
            person with no stated alternative is a single point of failure in a
            plan whose entire purpose is removing them.
        .PARAMETER Step
            Runbook steps, each with a name, an action, an expected result and
            optionally a verification command and a fallback.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Step
    )

    $index = 0
    foreach ($item in $Step) {
        $index++
        $name = [string](Get-OptionalProperty $item 'name')
        if ([string]::IsNullOrWhiteSpace($name)) { $name = "step $index" }

        $action = [string](Get-OptionalProperty $item 'action')
        $expected = [string](Get-OptionalProperty $item 'expected')
        $verify = [string](Get-OptionalProperty $item 'verify')
        $contact = [string](Get-OptionalProperty $item 'contact')
        $fallback = [string](Get-OptionalProperty $item 'fallback')

        if ([string]::IsNullOrWhiteSpace($action) -and [string]::IsNullOrWhiteSpace($contact)) {
            [pscustomobject]@{
                Severity = 'Error'; Step = $name
                Detail = "'$name' states no action. A step nobody can carry out is a note, not a step."
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($expected)) {
            [pscustomobject]@{
                Severity = 'Error'; Step = $name
                Detail = "'$name' does not say what success looks like, so whoever runs it cannot tell whether it worked."
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($action) -and [string]::IsNullOrWhiteSpace($verify)) {
            [pscustomobject]@{
                Severity = 'Warning'; Step = $name
                Detail = "'$name' has no verification command. Its result has to be judged by eye, which is how a drill and an incident start to differ."
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($contact) -and [string]::IsNullOrWhiteSpace($fallback)) {
            [pscustomobject]@{
                Severity = 'Warning'; Step = $name
                Detail = "'$name' depends on reaching $contact with no stated alternative. That person is a single point of failure in a plan meant to remove them."
            }
        }
    }
}

function Get-RecoveryOrder {
    <#
        .SYNOPSIS
            Orders recovery steps so nothing is brought up before what it needs.
        .DESCRIPTION
            Returns the order, or explains why there isn't one. Two failures are
            worth separating: a dependency on something the plan never mentions,
            which means the plan is incomplete, and a cycle, which means it can
            never be executed at all. Reporting either as a generic "invalid
            plan" leaves the reader to work out which.
        .PARAMETER Service
            Services, each with a name and the names it depends on.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Service
    )

    $known = @{}
    foreach ($item in $Service) {
        $name = [string](Get-OptionalProperty $item 'name')
        $known[$name] = @(Get-OptionalProperty $item 'dependsOn') | Where-Object { $_ }
    }

    $missing = @()
    foreach ($name in $known.Keys) {
        foreach ($dependency in $known[$name]) {
            if (-not $known.ContainsKey($dependency)) {
                $missing += "'$name' depends on '$dependency', which the plan does not cover"
            }
        }
    }
    if ($missing.Count) {
        return [pscustomobject]@{
            Order = @(); Valid = $false; Reason = 'IncompletePlan'
            Detail = $missing -join '; '
        }
    }

    # Kahn's algorithm. Names are sorted at each step so the same plan always
    # produces the same order, which matters when the output is a runbook people
    # compare between drills.
    $remaining = @{}
    foreach ($name in $known.Keys) { $remaining[$name] = @($known[$name]) }

    $order = @()
    while ($remaining.Count) {
        $ready = @($remaining.Keys | Where-Object {
            @($remaining[$_] | Where-Object { $remaining.ContainsKey($_) }).Count -eq 0
        } | Sort-Object)

        if ($ready.Count -eq 0) {
            return [pscustomobject]@{
                Order = @(); Valid = $false; Reason = 'CircularDependency'
                Detail = "These services depend on each other and cannot be ordered: $(($remaining.Keys | Sort-Object) -join ', ')."
            }
        }

        foreach ($name in $ready) {
            $order += $name
            $remaining.Remove($name)
        }
    }

    [pscustomobject]@{
        Order = $order; Valid = $true; Reason = $null
        Detail = "Recovery order: $($order -join ' -> ')."
    }
}

Export-ModuleMember -Function Measure-RecoveryObjective, Measure-DataLoss,
    Compare-ObjectiveToMeasurement, Test-RunbookStep, Get-RecoveryOrder
