# disaster-recovery-actually-failed-over

A database that fails over to a second region on demand, with the recovery time
and the data loss **measured** rather than quoted — and graded against the
objectives the plan claims, so a drill that misses them fails.

## The problem

Most disaster recovery plans have never been run. The ones that have are usually
timed from the wrong place.

The clock starts when somebody issues the failover command, which quietly
excludes detection and decision — the part of a real outage that is usually
longest and is the only part a runbook can actually improve. The result is a
document claiming a five-minute recovery for a process that has never taken less
than forty, because nobody ever measured the forty.

This lab fails a real Azure SQL failover group over between two regions, times
it from the first failed write, and counts what was lost by comparing writes
rather than clocks.

## What it measures, and why that way

**Recovery time starts at the failure.** Not at the decision, not at the
command. [`Measure-RecoveryObjective`](module/Recovery/Recovery.psm1) breaks the
outage into detection, decision, failover and reconnect so the expensive part is
visible. Hand it a timeline that only records the command and it returns the
number **with a caveat attached**, and the grader refuses to call it a pass —
being comfortably inside an objective measured from the wrong place is not the
same as meeting it.

**The outage ends when the service is back, not when the replica is writable.**
A promoted secondary helps nobody until the application is serving from it.

**Recovery point is data, not a clock.** "The last backup was five minutes ago"
is not an RPO. The real question is which writes the old primary *acknowledged*
that did not survive, so the drill writes numbered rows continuously and compares
what was acknowledged against what the new primary has.

**Nothing reconnects by changing a connection string.** Every query goes through
the failover group listener, which is the mechanism that makes the failover
invisible to an application. A drill that repoints its client has proved the
replica works and proved nothing about the recovery.

## The result that is easiest to fake

Observing no data loss does not mean no data loss is possible. It can equally
mean the drill did not write fast enough to catch any — four transactions in a
minute establishes almost nothing about a system taking hundreds a second.

So the write rate travels with the verdict, and below a threshold the result is
reported as **`Inconclusive`** rather than clean. A report whose worst outcome is
"we could not tell" teaches its readers to stop reading, so inconclusive fails
the drill:

| Verdict | Meaning |
|---|---|
| `NoLossObserved` | No acknowledged write was lost **at the observed rate** |
| `DataLost` | Acknowledged writes are missing; graded against the stated RPO |
| `OutOfOrderLoss` | An earlier write is missing while a later one survived — a correctness problem, not a recovery point gap |
| `Inconclusive` | Too few writes to support any conclusion |

## The runbook is checked too

A runbook is only useful if somebody who did not write it can follow it at three
in the morning. [`Test-RunbookStep`](module/Recovery/Recovery.psm1) cannot know
whether a step is *correct*, but it can insist each one is executable and
checkable:

- a step with no action is a note, not a step
- a step that never says what success looks like cannot be confirmed by anyone
  but its author
- a step naming a person with no stated fallback is a single point of failure in
  a plan whose purpose is removing them

CI runs this against [`recovery-plan.json`](recovery-plan.json), so a plan nobody
else could execute fails on a pull request instead of during an incident.
[`Get-RecoveryOrder`](module/Recovery/Recovery.psm1) separately checks the
services can actually be brought up in dependency order, distinguishing a plan
that is *incomplete* (depends on something it never mentions) from one that is
*impossible* (a cycle) — reporting both as "invalid" leaves the reader to work
out which.

## Failing back is part of the drill

A plan that only goes one way leaves the estate running unprotected in the region
it fled to, which is worse than where it started. The drill fails back and
confirms the original region is primary again before it reports success.

## Cost

S0 DTU databases rather than serverless, and the reason is cost rather than
capability:

| | Per hour, both replicas | A two-hour drill |
|---|---|---|
| General Purpose serverless, 0.5 vCore | $0.52 | ~$1.04 |
| **Standard S0** | **$0.040** | **~$0.08** |

A geo-replicated secondary cannot auto-pause, so serverless bills continuously on
both sides — the thing serverless is good at is exactly what a failover group
prevents. The failover mechanics are identical either way. At real volumes the
tier would be chosen by the workload instead.

The drill tears itself down in the same job, including when it fails, because a
lab that only cleans up on the happy path bills for its own bugs. A nightly
workflow removes anything a cancelled run left behind, deleting by resource group
name rather than from Terraform state — the drill discards its state with the
runner, so a state-based destroy would find nothing to do and report success over
two live databases.

## Running it

```bash
terraform -chdir=infra init
terraform -chdir=infra apply \
  -var entra_admin_object_id=<principal> -var entra_admin_login=<name>
```

Then run **Drill** from the Actions tab. Region pair defaults to
`westus2 -> westcentralus`, an official Azure pair. Check before changing it: the
capabilities API reports a region as `Visible` when it is listed but will refuse
to provision into it, which fails at apply time with `ProvisioningDisabled`
rather than at plan time.

## What five live runs found

The drill took five attempts against real infrastructure, and the failures are
the useful part.

**`az sql failover-group set-primary` has no `--no-wait`.** The first run was
rejected for an unrecognised argument — and the script had piped the command's
output to `Out-Null`, so it reported only *"the failover command was rejected"*,
the least useful true thing it could have said. The deeper problem was design:
that command blocks until failover completes, so nothing would have been writing
during the switch and the outage would have happened with nobody watching. It now
goes through ARM, which returns `202 Accepted` immediately.

**The drill reported a decision phase of minus 7.2 seconds.** No write had
failed, and rather than carry that absence through, the script filled the
missing failure time in from the restore time so there would always be a number
— which placed the failure *after* the failover command and made the subtraction
run backwards. A drill reporting a negative interval is the self-flattery this
lab exists to catch. The absence is now an absence, graded as *no outage
observed* rather than a measured zero.

**The biggest one: the control plane reports the failover complete before the
data plane agrees.** ARM reported the secondary as `Primary`, a write succeeded,
and the drill called that the moment service returned. It wasn't: that write went
to the **old** primary, which had not yet been demoted — so it is precisely the
write most likely to be lost. The recovery was being timed against the wrong
replica, and the data loss comparison then read its surviving rows from that same
wrong replica.

This surfaced only because an earlier run had added a `Updateability` check to
resolve a *different* uncertainty — `@@SERVERNAME` was returning the original
server after a confirmed failover, and rather than guess what that meant, the
check was replaced with one whose meaning is unambiguous: a geo-secondary is
`READ_ONLY`, so `READ_WRITE` establishes that the promoted replica is answering.
A check added for one reason caught something else entirely.

The outage now ends only when the control plane has swapped **and** the
connection is served read-write. An earlier run that passed did so by timing
luck, not by being right.

## Status

| | |
|---|---|
| Unit tests | 36, green, no database required |
| PSScriptAnalyzer, `terraform validate`, `tflint`, `checkov`, `actionlint` | clean |
| Live drill | **passed**, `westus2 -> westcentralus` |
| Teardown | **verified**: 0 resource groups, 0 SQL servers |

From the passing run:

```
601 writes acknowledged before the failover was commanded
no write ever failed: the outage was shorter than the gap between two writes
the listener is serving a READ_WRITE replica

recovery time   0.0 s, measured from no outage observed
  failover      7.3 s
recovery point  NoLossObserved at 12.21 writes/second over 52.9 s
failback        1.8 s, the original region is Primary again
```

**On those two numbers.** The 7.3 s failover is measured by polling the control
plane every 5 seconds, so the true figure is somewhere between 2.3 s and 7.3 s;
the poll interval is recorded in the report rather than left for a reader to
assume it was exact. The 1.8 s failback is not directly comparable — it uses the
blocking command, so it is measured precisely. Nothing is being timed on the way
back, which is why the simpler call is the right one there.

**And on the headline result.** *No outage observed* is not the same as *no
outage*. At 12 writes per second the gap between two writes is about 80
milliseconds, so this establishes the outage was shorter than that, at that rate.
A system taking hundreds of writes a second would have seen more.

## What this does not do

It covers one stateful tier. A real estate has stateless services, DNS, secrets,
and dependencies between them, and the module's dependency ordering is exercised
against a declared plan rather than against live services.

It also performs a **planned** failover — the kind available when the primary
region is still reachable. A forced failover, where the region is genuinely gone
and recently committed work can be lost, is the case the stated five-second RPO
exists for; this drill measures the planned path and reports the rate its result
rests on rather than claiming the forced path by implication.
