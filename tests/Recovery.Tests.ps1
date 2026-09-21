#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $modulePath = [System.IO.Path]::Combine($PSScriptRoot, '..', 'module', 'Recovery', 'Recovery.psm1')
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:T0 = [datetime]'2026-09-21T10:00:00Z'

    function New-Timeline {
        param(
            [object]$FailedAt = 0, [object]$DetectedAt = 40,
            [object]$StartedAt = 70, [object]$CompletedAt = 100, [object]$RestoredAt = 120
        )
        $o = [ordered]@{}
        if ($null -ne $FailedAt) { $o['FailedAt'] = $script:T0.AddSeconds($FailedAt) }
        if ($null -ne $DetectedAt) { $o['DetectedAt'] = $script:T0.AddSeconds($DetectedAt) }
        if ($null -ne $StartedAt) { $o['FailoverStartedAt'] = $script:T0.AddSeconds($StartedAt) }
        if ($null -ne $CompletedAt) { $o['FailoverCompletedAt'] = $script:T0.AddSeconds($CompletedAt) }
        if ($null -ne $RestoredAt) { $o['ServiceRestoredAt'] = $script:T0.AddSeconds($RestoredAt) }
        [pscustomobject]$o
    }
}

Describe 'Measure-RecoveryObjective' {
    It 'measures the whole outage from the failure' {
        $r = Measure-RecoveryObjective -Timeline (New-Timeline)
        $r.RecoveryTimeSeconds | Should -Be 120
        $r.MeasuredFrom | Should -Be 'failure'
        $r.Caveat | Should -BeNullOrEmpty
    }

    It 'ends the outage at service restored, not at failover completed' {
        # Failover completed at 100s, service restored at 120s. A report that
        # stops at 100 understates the outage by the reconnect time.
        $r = Measure-RecoveryObjective -Timeline (New-Timeline -CompletedAt 100 -RestoredAt 120)
        $r.RecoveryTimeSeconds | Should -Be 120
        $r.Breakdown['reconnect'] | Should -Be 20
    }

    It 'breaks the outage into detection, decision, failover and reconnect' {
        $r = Measure-RecoveryObjective -Timeline (New-Timeline)
        $r.Breakdown['detection'] | Should -Be 40
        $r.Breakdown['decision'] | Should -Be 30
        $r.Breakdown['failover'] | Should -Be 30
        $r.Breakdown['reconnect'] | Should -Be 20
    }

    # The flattering measurement this module exists to refuse.
    It 'says so when the timeline only starts at the failover command' {
        $r = Measure-RecoveryObjective -Timeline (New-Timeline -FailedAt $null -DetectedAt $null)
        $r.RecoveryTimeSeconds | Should -Be 50
        $r.MeasuredFrom | Should -Be 'the failover command'
        $r.Caveat | Should -Match 'detection and decision'
    }

    It 'says so when the timeline starts at detection' {
        $r = Measure-RecoveryObjective -Timeline (New-Timeline -FailedAt $null)
        $r.RecoveryTimeSeconds | Should -Be 80
        $r.MeasuredFrom | Should -Be 'detection'
        $r.Caveat | Should -Match 'went unnoticed'
    }

    It 'refuses a timeline with no recovery in it' {
        { Measure-RecoveryObjective -Timeline (New-Timeline -RestoredAt $null) } |
            Should -Throw -ExpectedMessage '*no ServiceRestoredAt*'
    }
}

Describe 'Measure-DataLoss' {
    It 'reports no loss observed when everything acknowledged survived' {
        $acked = 1..60
        $r = Measure-DataLoss -Acknowledged $acked -Surviving $acked -WindowSeconds 60
        $r.Verdict | Should -Be 'NoLossObserved'
        $r.LostCount | Should -Be 0
    }

    # No loss at 1/second is not evidence about a system doing hundreds.
    It 'reports the rate the no-loss result rests on' {
        $acked = 1..60
        $r = Measure-DataLoss -Acknowledged $acked -Surviving $acked -WindowSeconds 60
        $r.WritesPerSecond | Should -Be 1
        $r.Detail | Should -Match 'not proof that loss is impossible'
    }

    It 'counts acknowledged writes that did not survive' {
        $r = Measure-DataLoss -Acknowledged (1..60) -Surviving (1..55) -WindowSeconds 60
        $r.Verdict | Should -Be 'DataLost'
        $r.LostCount | Should -Be 5
        $r.LostSequences | Should -Contain 60
    }

    # A drill too small to catch anything must not be called clean.
    It 'calls a drill with too few writes inconclusive rather than clean' {
        $r = Measure-DataLoss -Acknowledged (1..4) -Surviving (1..4) -WindowSeconds 60
        $r.Verdict | Should -Be 'Inconclusive'
        $r.Conclusive | Should -BeFalse
        $r.Detail | Should -Match 'too few'
    }

    It 'honours a lowered minimum when the caller sets one' {
        $r = Measure-DataLoss -Acknowledged (1..4) -Surviving (1..4) -WindowSeconds 60 -MinimumWrites 3
        $r.Verdict | Should -Be 'NoLossObserved'
    }

    # Losing an earlier write while a later one survived is a correctness
    # problem, not a recovery point gap.
    It 'separates out-of-order loss from a recovery point gap' {
        $surviving = @(1..50) + @(60)
        $r = Measure-DataLoss -Acknowledged (1..60) -Surviving $surviving -WindowSeconds 60
        $r.Verdict | Should -Be 'OutOfOrderLoss'
        $r.Detail | Should -Match 'out of order'
    }

    It 'handles a total loss of the secondary without dividing by zero' {
        $r = Measure-DataLoss -Acknowledged (1..60) -Surviving @() -WindowSeconds 0
        $r.LostCount | Should -Be 60
        $r.WritesPerSecond | Should -Be 0
    }
}

Describe 'Compare-ObjectiveToMeasurement' {
    BeforeAll {
        $script:Objective = [pscustomobject]@{ RtoSeconds = 300; RpoSeconds = 0; why = 'test' }
        $script:CleanLoss = [pscustomobject]@{
            Verdict = 'NoLossObserved'; LostCount = 0; WritesPerSecond = 1
            Detail = 'no loss'; Conclusive = $true
        }
    }

    It 'passes a recovery inside the objective measured from the failure' {
        $recovery = Measure-RecoveryObjective -Timeline (New-Timeline)
        $r = Compare-ObjectiveToMeasurement -Objective $script:Objective -Recovery $recovery -DataLoss $script:CleanLoss
        $r.Passed | Should -BeTrue
        $r.RtoMet | Should -BeTrue
    }

    It 'fails a recovery that exceeded the objective' {
        $recovery = Measure-RecoveryObjective -Timeline (New-Timeline -RestoredAt 400)
        $r = Compare-ObjectiveToMeasurement -Objective $script:Objective -Recovery $recovery -DataLoss $script:CleanLoss
        $r.RtoMet | Should -BeFalse
        $r.Passed | Should -BeFalse
    }

    # Comfortably inside an objective measured from the wrong place is not
    # the same as meeting it.
    It 'refuses to pass an RTO measured from the failover command' {
        $recovery = Measure-RecoveryObjective -Timeline (New-Timeline -FailedAt $null -DetectedAt $null)
        $r = Compare-ObjectiveToMeasurement -Objective $script:Objective -Recovery $recovery -DataLoss $script:CleanLoss
        $recovery.RecoveryTimeSeconds | Should -BeLessThan 300
        $r.RtoMet | Should -BeFalse
        $r.RtoDetail | Should -Match 'not valid'
    }

    It 'fails an inconclusive data loss result rather than passing it' {
        $recovery = Measure-RecoveryObjective -Timeline (New-Timeline)
        $loss = [pscustomobject]@{ Verdict = 'Inconclusive'; LostCount = 0; WritesPerSecond = 0.1; Detail = 'too few'; Conclusive = $false }
        $r = Compare-ObjectiveToMeasurement -Objective $script:Objective -Recovery $recovery -DataLoss $loss
        $r.RpoMet | Should -BeFalse
        $r.Passed | Should -BeFalse
    }

    It 'allows loss within a non-zero recovery point objective' {
        $recovery = Measure-RecoveryObjective -Timeline (New-Timeline)
        $objective = [pscustomobject]@{ RtoSeconds = 300; RpoSeconds = 60; why = 'test' }
        $loss = [pscustomobject]@{ Verdict = 'DataLost'; LostCount = 10; WritesPerSecond = 1; Detail = 'lost 10'; Conclusive = $true }
        $r = Compare-ObjectiveToMeasurement -Objective $objective -Recovery $recovery -DataLoss $loss
        $r.RpoMet | Should -BeTrue
        $r.RpoDetail | Should -Match '10 s of work'
    }

    It 'fails loss beyond a non-zero recovery point objective' {
        $recovery = Measure-RecoveryObjective -Timeline (New-Timeline)
        $objective = [pscustomobject]@{ RtoSeconds = 300; RpoSeconds = 5; why = 'test' }
        $loss = [pscustomobject]@{ Verdict = 'DataLost'; LostCount = 30; WritesPerSecond = 1; Detail = 'lost 30'; Conclusive = $true }
        $r = Compare-ObjectiveToMeasurement -Objective $objective -Recovery $recovery -DataLoss $loss
        $r.RpoMet | Should -BeFalse
    }
}

Describe 'Test-RunbookStep' {
    It 'passes a step a stranger could carry out and confirm' {
        $step = @([pscustomobject]@{
            name = 'Fail the group over'; action = 'az sql failover-group set-primary ...'
            expected = 'replicationRole reports Primary in the secondary region'
            verify = 'az sql failover-group show --query replicationRole'
        })
        @(Test-RunbookStep -Step $step).Count | Should -Be 0
    }

    It 'rejects a step that states no action at all' {
        $r = @(Test-RunbookStep -Step @([pscustomobject]@{ name = 'Think about it'; expected = 'clarity' }))
        ($r | Where-Object Severity -eq 'Error').Detail | Should -Match 'states no action'
    }

    # The author knows what success looks like; the person at 3am does not.
    It 'rejects a step that never says what success looks like' {
        $r = @(Test-RunbookStep -Step @([pscustomobject]@{ name = 'Run it'; action = 'do the thing'; verify = 'check' }))
        ($r | Where-Object Severity -eq 'Error').Detail | Should -Match 'what success looks like'
    }

    It 'warns about a step with no verification command' {
        $r = @(Test-RunbookStep -Step @([pscustomobject]@{ name = 'Run it'; action = 'do the thing'; expected = 'it worked' }))
        ($r | Where-Object Severity -eq 'Warning').Detail | Should -Match 'no verification command'
    }

    It 'warns when a named person has no stated alternative' {
        $r = @(Test-RunbookStep -Step @([pscustomobject]@{
            name = 'Approve failover'; contact = 'the on-call DBA'; expected = 'approval given' }))
        ($r | Where-Object Severity -eq 'Warning').Detail | Should -Match 'single point of failure'
    }

    It 'accepts a contact step that names a fallback' {
        $r = @(Test-RunbookStep -Step @([pscustomobject]@{
            name = 'Approve failover'; contact = 'the on-call DBA'; expected = 'approval given'
            fallback = 'after 10 minutes the incident lead may approve' }))
        ($r | Where-Object Severity -eq 'Warning').Count | Should -Be 0
    }

    It 'accepts an empty runbook without error' {
        @(Test-RunbookStep -Step @()).Count | Should -Be 0
    }
}

Describe 'Get-RecoveryOrder' {
    It 'brings dependencies up before the things that need them' {
        $services = @(
            [pscustomobject]@{ name = 'app'; dependsOn = @('database') },
            [pscustomobject]@{ name = 'database'; dependsOn = @() }
        )
        $r = Get-RecoveryOrder -Service $services
        $r.Valid | Should -BeTrue
        $r.Order[0] | Should -Be 'database'
        $r.Order[1] | Should -Be 'app'
    }

    It 'orders a longer chain correctly' {
        $services = @(
            [pscustomobject]@{ name = 'web'; dependsOn = @('api') },
            [pscustomobject]@{ name = 'api'; dependsOn = @('database', 'cache') },
            [pscustomobject]@{ name = 'cache'; dependsOn = @() },
            [pscustomobject]@{ name = 'database'; dependsOn = @() }
        )
        $r = Get-RecoveryOrder -Service $services
        $r.Valid | Should -BeTrue
        [array]::IndexOf($r.Order, 'database') | Should -BeLessThan ([array]::IndexOf($r.Order, 'api'))
        [array]::IndexOf($r.Order, 'api') | Should -BeLessThan ([array]::IndexOf($r.Order, 'web'))
    }

    # An incomplete plan and an impossible one need different answers.
    It 'reports a dependency the plan never covers as incomplete' {
        $services = @([pscustomobject]@{ name = 'app'; dependsOn = @('database') })
        $r = Get-RecoveryOrder -Service $services
        $r.Valid | Should -BeFalse
        $r.Reason | Should -Be 'IncompletePlan'
        $r.Detail | Should -Match "does not cover"
    }

    It 'reports a cycle as a cycle' {
        $services = @(
            [pscustomobject]@{ name = 'a'; dependsOn = @('b') },
            [pscustomobject]@{ name = 'b'; dependsOn = @('a') }
        )
        $r = Get-RecoveryOrder -Service $services
        $r.Valid | Should -BeFalse
        $r.Reason | Should -Be 'CircularDependency'
    }

    It 'produces the same order every time for the same plan' {
        $services = @(
            [pscustomobject]@{ name = 'zeta'; dependsOn = @() },
            [pscustomobject]@{ name = 'alpha'; dependsOn = @() }
        )
        $first = (Get-RecoveryOrder -Service $services).Order -join ','
        $second = (Get-RecoveryOrder -Service $services).Order -join ','
        $first | Should -Be $second
        $first | Should -Be 'alpha,zeta'
    }

    It 'handles an empty plan' {
        $r = Get-RecoveryOrder -Service @()
        $r.Valid | Should -BeTrue
        @($r.Order).Count | Should -Be 0
    }
}
