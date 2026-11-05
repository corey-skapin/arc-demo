# Troubleshooting

Known failure modes with verified observations, fixes where established, and
explicit unresolved boundaries. Confirm the runtime tenant/subscription and get
scoped approval before any repair, restart, policy scan or fault operation.
This is a symptom reference, not required presenter reading; use
[the docs index](README.md) and [runsheet.md](runsheet.md) for the default tour.

## Nested SQL build and cold-wake lessons

Use the [short nested SQL runbook](nested-sql-demo.md), not retired V1-V3
provisioning, first-boot or review controllers.

| Symptom | Working-path lesson |
|---|---|
| Scratch Windows boot fails with `c000003a` | Use Server 2022 BCDBoot for the Server 2022 guest; the Server 2019 binary failed. |
| Arc connect writes informational stderr under Windows PS5 | Capture native stdout/stderr and use the process exit code plus actual Arc connection; informational stderr alone is not failure. |
| Managed Run Command creation fails at 25 saved commands | The VM limit is 25. Use the retained helper's completed demo-command cleanup; never remove another command or an in-flight operation. |
| Hyper-V rejects `Stop-VM -Shutdown` | `-Shutdown` is not a valid parameter. Normal `Stop-VM -Confirm:$false` requests graceful shutdown; wait for Off before parking the parent. |
| Downloads/onboarding fail just after static-IP setup | Cold DNS can lag. Wait for DNS/network readiness; do not repeatedly rebuild the guest or reset credentials. |
| A large parent is unexpectedly deallocated | The platform can deallocate it during the demo. Inspect its actual power state and use Activate; do not treat missing guest output as a reason to rebuild. |
| SQL extension is not immediately healthy after wake | Arc connection and SQL extension readiness are different. Allow bounded startup lag and run the SQL status helper; do not reinstall or reconnect automatically. |

## LOB app has only old error events in Log Analytics

The healthy LOB worker emits Application event `4000` at Information level,
not the fault-only `4100` Error. The older core DCR collected only Application/
System warning/error/critical events, so a healthy running worker could have
fresh local logs but only historical fault events in Log Analytics. Check the
live selector and Arc-resource DCRA before assuming the task stopped.

The current definition adds only provider `ArcLobBridgeApp`, event `4000`,
level `4`; it does not broaden all informational collection or start the sample.
For an existing lab, obtain approval for that narrow collection change and allow
agent propagation/ingestion time. Verify new post-change records rather than
historical rows. Use the [LOB sample's healthy activity query](../samples/lob-arc-app/README.md#showing-healthy-activity-in-log-analytics).
Guest task/config/log inspection and any start/fault/repair need their own scope;
do not induce a fault just to make this query nonempty.

## SQL preparation reports a pending file rename

**Symptom** — wrapper step P5.3 (or `Invoke-SqlEngineOnArc.ps1 -Action Install`) stops after about a
minute with `A reboot/pending rename is recorded (PendingFileRenameOperations: ...)`. The wrapper words
it as "A reboot/pending rename is recorded".

**Cause** — a nonempty `PendingFileRenameOperations` value on a fresh Windows host is usually routine
installer leftovers (in the build that found this: an Edge updater folder, `Amcache.hve.tmp` and an NSIS
temp folder, with the Component Based Servicing and Windows Update flags clear, no installer running and
the last boot at VM creation). The error now lists the first eight pending sources so you can judge that.
It does not identify the owning package or prove an active installer, and SQL Server setup itself refuses
a host with a pending restart, so the [real SQL helper](sql-engine-workload.md) fails closed before
installation and never deletes the value or skips setup checks.

**Fix** — keep the running lab otherwise unchanged and ask the owner for **one graceful restart** of that
VM; request it together with the other approvals for the build, not when the step fails. Then:

1. Read-only first: confirm in the error (or the guest) that only routine entries are listed and no
   installer is running.
2. With approval, restart once from Azure: `az vm restart --subscription <SUB> -g rg-<prefix>-infra -n <vm>`
   (about 45 seconds). Never restart from inside the guest or repeatedly.
3. Rerun the step (`-Only P5`, or `Invoke-SqlEngineOnArc.ps1 -Action Install`). It waits up to six minutes
   for `himds`, `ExtensionService` and `GCArcService` (running about 3.5 minutes after the restart) and
   `MonAgentCore` (about 4.5 minutes) before its Arc SQL block check, which requires all four.

If the value is still set after a restart, or the list names something other than routine leftovers,
stop and obtain separate scope for deeper diagnosis.

## Media staging stops on a size or hash mismatch

**Symptom** — `Stage-DemoMedia.ps1` throws `has SHA-256 ..., not the pinned ...`,
`more than the pinned ...` or `Existing <file> ... refusing to overwrite it`.

**Cause** — The file on the VM, or the download, does not match the size and
SHA-256 pinned in `config\demo-media.json`. Microsoft can refresh the Evaluation
ISO behind its fixed link, and a damaged or tampered file looks the same. The
script never overwrites a mismatching existing file, and it discards a mismatching
download so it cannot take the final name.

**Fix** — An interrupted download is not a mismatch: run again and it resumes.
If Microsoft refreshed the file, confirm the new size and SHA-256 from the
publisher or two independent downloads, update `bytes` and `sha256` in the
manifest as a reviewed change, and accept the terms again. Never skip the check or
supply a different hash on the command line. For a wrong file already on the VM,
inspect it first and remove it deliberately.

## Directory CLI rejects --subscription

`az ad` operations are tenant-scoped; commands such as `az ad sp show` do not
accept `--subscription`. The checked adapter does not append that argument to
directory commands. Before any directory read/write it verifies the CLI's actual
default tenant matches the explicit requested tenant, and stops on mismatch.
It never silently switches defaults to make an identity operation succeed.

## Multiline Azure CLI arguments are truncated on Windows

**Symptom** — A multiline Resource Graph query returns unfiltered resources, or
an inline guest script does not execute its later lines.

**Cause** — Passing embedded newlines through the Windows `az.cmd` launcher can
truncate the native argument at its first line. A successful CLI exit is not proof
that the intended query/script was transported.

**Fix** — For REST queries, send the complete query in a JSON request body. For
simple KQL without line comments, flatten line breaks before invoking the CLI and
verify the result shape. Guest commands use the documented
[`--scripts @script.ps1` file form](https://learn.microsoft.com/azure/virtual-machines/windows/run-command#using-run-commands).
`Invoke-DemoGuestCommand` retains its temporary UTF-8 script until the bounded job
finishes and removes it on success/failure. Do not print credential-bearing scripts.

## Linux ARM Updating while monitoring guest handlers are healthy

Inspect ARM model state, VM guest instance view, recent activity and exact-ID
telemetry separately. An outstanding MDE.Linux operation can coincide with AMA
and Change Tracking reporting ARM Updating even when their guest handlers report
Succeeded and data continues to arrive. A read-only look at one awake Linux host
showed the VM provisioning state `Updating`, `MDE.Linux` `Transitioning` (the guest
agent reported no status file) and the other handlers Ready, still so about 75
minutes after wake with fresh Heartbeats. The cause (an orphaned install lock in the
vendor's MDE.Linux handler) and the recovery are in
[A Linux VM stays Updating behind a Defender MDE.Linux install lock](#a-linux-vm-stays-updating-behind-a-defender-mdelinux-install-lock).

**Not a gate.** Extension provisioning state (AMA, Change Tracking, MDE) is a soft
warning, not a readiness condition. Activation prints `extension <name> Updating for
at least <n> min (not a gate)`, and readiness shows non-required `extension/*` rows
(state, how long the host's Arc identity has been connected, a pointer here), so the
overall status follows the required `heartbeat/*` rows. Do not force Heartbeat green
and do not wait for these rows to clear before presenting. A `Failed` AMA extension
with no Heartbeat is different: that is a real failure. A missing MDE status file is
not proof of working endpoint protection.
Preserve healthy AMA/CT and DCRAs; agree a targeted recovery before retrying MDE or
restarting anything. No reinstall/restart is part of read-only rehearsal preflight.

## A Linux VM stays Updating behind a Defender MDE.Linux install lock

**Symptom** — a Linux VM reads `Updating` and its `MDE.Linux` extension `Transitioning` for far longer than a
wake or a deployment should take, while the guest is healthy: the agent is active, Heartbeats are fresh and AMA
and Change Tracking run. A Deploy rerun waits at that VM's module with nothing else wrong, and a Run Command sent
to it queues. It recurs, because Defender pushes the extension about hourly: in one build window three Linux VMs
spent most of four hours `Updating`. Readiness shows non-required `provisioning/<vm>` and `extension/<vm>/MDE.Linux` rows.

**Cause** — the vendor's MDE.Linux handler (observed in version 1.0.16.6) writes an install lock with a 36-minute
expiry at the end of every real `enable`, even when its installer wrapper already finished and removed its own, so
every real `enable` on a healthy host leaves an orphan lock. An `enable` inside that window logs "Installation
already in progress." and writes no status file, so ARM keeps the VM `Updating` until the platform times the write
out (about 90 minutes) or a new goal state reaches the guest after the lock is over 36 minutes old. Defender's push
skips a VM whose write is still open. Defender for Servers Plan 2 provisions the VM-path and the Arc-path
`MDE.Linux` extension on a simulated host, and they share one handler directory, lock and status directory with
colliding sequence numbers, so an Arc-path `Succeeded` is not evidence of an install. Anything that makes the
handler run `enable` within 36 minutes before a push seeds the stall: a Run Command, a Deploy re-PUT of the VM, a
tag edit (a write now, a propagation write about 10 minutes later, and a Defender re-push minutes after the first)
or a boot of the VM. `ExcludeMdeAutoUpdate=true` on the VM and the Arc machine did not stop the push. This is a
defect in the vendor extension: nothing here removes, reinstalls or patches Defender.

**What to do**

- Treat it as a soft warning and present normally; the required `heartbeat/*` rows decide readiness.
- Wait. The platform releases the open write at about 90 minutes and the VM becomes `Succeeded` with no action.
- Do not cancel the update, remove or reinstall Defender, restart the agent or the VM, or send a Run Command to a VM
  whose `MDE.Linux` is `Transitioning` with a fresh lock: it queues and then blocks the one nudge that could help.
- If recovery cannot wait, ask the owner first, then send exactly ONE new goal state (`az vm reapply`, or a read-only
  Run Command) only when the last `enable` is more than 36 minutes old and right after a Defender push. A nudge
  resets the lock clock, so one sent shortly before the next push recreates the stall.
- When the VM channel is stuck, inspect through the Arc channel (`az connectedmachine run-command create`, preview and
  best effort). It only inspects: an Arc-channel run command produces no goal state and cannot heal the VM.
- Deploy warns before it submits when a VM is already `Updating` and then polls its deployment with progress, so the
  wait is visible rather than silent. It does not skip, cancel or reorder anything.
- What a deallocate does to a VM that is `Updating` (queue, conflict or success) has not been tested. Hibernate
  submits the deallocation without waiting and then waits up to 20 minutes for the VM to read deallocated; if it
  does not, the run fails with an error rather than reporting verified stopped compute, and a rerun after the VM
  settles finishes the job; see [the lifecycle note](lifecycle.md#linux-vms-and-the-defender-mdelinux-install-lock).

The defect belongs to the Defender for Endpoint extension owners (create the lock before starting the wrapper and
delete it when the wrapper ends, or write a status file in the "already in progress" branch, and do not share one
handler directory between the VM and Arc paths). It has not been reported upstream from this repository.

## Activation fails parsing an absent NAT or public IP

**Observed cause** - After hibernation removes the owned NAT/PIP, activation
can fail before any mutation with `ConvertFrom-Json: Cannot bind argument to
parameter 'InputObject' because it is null`. The checked CLI adapter returns
an explicit null for a recognized not-found response. Piping that null directly
to the JSON parser fails under terminating errors; a same-process preview can
instead print errors and return, so its exit code alone is insufficient proof.

**Fix** - The shared network preflight parses optional NAT/PIP JSON only when
the adapter returns a value. It still checks exact identities and sharing, and
propagates authorization, CLI and malformed-JSON errors. Use the corrected source
for both normal `-WhatIf` and activation with the retained target/skin. Do not
manually create network resources or suppress errors to bypass this check.

## Standalone WhatIf reports a CLI failure with empty error details

**Observed cause** - PowerShell preview can apply `WhatIfPreference` to the
checked CLI adapter's local stderr redirection, printing `What if: Output to
File` instead of capturing the error. An expected parked NAT/PIP not-found
response then loses its recognized error code and fails closed as a generic
nonzero CLI exit. This is not evidence of an authorization denial.

**Fix** - The adapter temporarily disables preview only within its local command
transport and restores the preference in `finally`, including on failure.
Caller `ShouldProcess` boundaries still prevent preview from issuing Azure
mutations; native Azure CLI commands never honored PowerShell preview themselves.
Recognized absence, real denials and other nonzero exits retain their stderr.
Use the corrected normal standalone preview, not error suppression or manual
resource creation.

## Activation fails at Windows guest completion even though Monitor becomes Ready

**Observed cause** - The old script attempted
`Restart-Service himds,AzureMonitorAgent`. On the inspected Windows Arc host,
`himds` was running but no `AzureMonitorAgent` SCM service existed. A separately
approved read-only guest invocation returned a valid stdout completion marker;
the marker/transport was not broken. Do not treat its absence in the original
failed command as evidence that the guest script never ran.

**Fix** - Activation no longer runs a guest script by default: it waits for a
Heartbeat generated after the VM start
([the shared wait](#linux-activation-waits-behind-a-vm-extension-update)). The
opt-in `-GuestChecks WhenStalled|Always` script checks Windows Arc AMA through
`MonAgentCore`, as described
in [Microsoft's Windows Arc troubleshooting guidance](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-troubleshoot-windows-arc),
and restarts real required services only with `-RepairStalledAgents`. Missing
services, failed status entries and absent stdout markers still fail.
The helper reports safe status metadata without logging potentially sensitive
guest output. Optional `-ResultPath` retains per-host outcomes and failures.

With scoped activation approval, rerun the corrected script with the same
explicit target and retained skin. Do not add skip switches, reinstall AMA,
restart the VM/extension host or equate an independent Ready snapshot with a
successful activation. Assessment submissions still run unless explicitly skipped;
they are asynchronous, not proof of completed update inventory.

## Windows AMA is healthy but starts after the old three-minute guard

An approved cold-start diagnosis found `MonAgentCore` naturally starting about
five minutes after boot, roughly half a minute after the old guard failed.
Fresh exact-ID Heartbeat followed; no repair was needed. That observation is not
a guarantee of future boot/ingestion time.

Activation now waits up to the shared deadline (12 minutes by default) for a
Heartbeat generated after the VM start; the first Windows Heartbeats were observed
after 7.6-8.4 minutes. A host still without one at the deadline is recorded pending
in `-ResultPath`; nothing is restarted or reinstalled. The opt-in guest script keeps
its own ten-minute AMA wait and explicit pending marker. Final readiness
reports telemetry lag separately. If only Heartbeat is pending, activation exits
0 with pending evidence and a re-check message. Poll read-only readiness before
presenting or the combined incident offer; report pending if it does not converge.
Do not turn an auth failure, unhealthy service or failed extension into telemetry
lag. Microsoft documents both the
[MonAgentCore process and a further Heartbeat wait](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-troubleshoot-windows-arc#basic-troubleshooting-steps-installation-agent-not-running-configuration-issues);
the budgets here are this repo's policy, not a service SLA.

## Hibernate finds missing manifests, an extra VM or a foreign NAT

Parking no longer requires perfect deployment/skin/OS metadata. It warns about
strict inventory drift, then parks every discovered VM, AKS cluster and active
Container App revision in the explicitly selected demo infra group. If a skin
cannot be read, supply the confirmed prefix explicitly; never guess another lab.
One failed compute stop does not prevent attempts on the other workloads.
Final Hibernated checks require actual known deallocation/stopped/inactive state.
Denied/unknown power stays an explicit error, not success.

A foreign/shared NAT/PIP binding skips **only** network cleanup with a loud
warning. Safe cleanup remains detach subnet, delete NAT, delete PIP, after compute
parking. Incomplete network deletion is visible and may bill even when the
compute checks pass. Inspect those non-required cost rows; do not claim a zero
bill or change foreign bindings. Retained monitoring is not queried in parked
readiness. Repair manifest/skin drift before a separately approved activation;
startup, deployment and destructive removal remain fail-closed.

## An Arc Linux extension child is absent but the VM-path extension is present

Inspect the exact `Microsoft.HybridCompute/machines/extensions` and
`Microsoft.Compute/virtualMachines/extensions` IDs separately. Post-startup
observations found absent Arc MDE/patch children while the three Linux VM-path
AMA, Change Tracking and MDE extension models reported Succeeded. That neither
identifies who removed an Arc child nor establishes active sensor/AV/EDR health.
Update Manager can manage temporary assessment extensions. Keep these observations
separate from guest service/marker failures; do not delete/reinstall extensions
or change policy to make resource counts match.

## Linux MDE timed out, but the installed sensor reports healthy

The inspected MDE.Linux operations failed with `ResourceOperationFailure` /
`VMExtensionProvisioningTimeout`, last reporting "Plugin enabled"; guest status
reported a missing status file. That identifies the failure mode, not its cause.
After separately approved VM starts, all three extension models converged to
Succeeded/onboarding Success without a manual MDE repair. Existing logs recorded
an interrupted installation, resumed onboarding and "Installation already in
progress". Do not turn an old package error from another date into a current
root-cause claim.

Direct diagnostics reported `healthy=true`, `licensed=true`, an active service
and no direct health issues, but passive mode was enabled, real-time protection
disabled and the engine not loaded. Two extension payloads still recorded
event-provider issues differing from direct health. Do not claim active AV/full
EDR or blindly reinstall a working sensor. Keep timestamped observations separate;
review policy intent and the discrepancy under a new approved diagnostic scope
before proposing a targeted change. See [lifecycle boundaries](lifecycle.md).

## Linux activation waits behind a VM extension update

**Observed cause** - After wake, Defender auto-provisioning can leave the MDE
extension transitioning and the VM and its other extension operations `Updating`.
Run Command queues behind that operation. In the 1 November rehearsal each blocked
Linux VM reached the old 15-minute checked-job timeout, collected one VM at a time
with a fresh clock, and activation then failed although Heartbeats were fresh and
the VM agent reported Ready (first Heartbeats arrived after 3-4 minutes on Linux and
7.6-8.4 on Windows). It is intermittent: the 2 November wake finished in about 13
minutes with every guest check passing, yet six Linux AMA/Change Tracking extension
models were still `Updating` 26 minutes later.

**Fix** - Activation no longer uses Run Command for host checks by default. One
shared wait with a single deadline (`-GuestCheckMinutes`, default 12) passes a host on
VM running, Arc `Connected` and a Heartbeat generated after the VM start, and treats
extension state as a soft warning (see the
[Linux ARM Updating symptom](#linux-arm-updating-while-monitoring-guest-handlers-are-healthy)).
A host with no Heartbeat at the deadline is pending for that host only. With
`-GuestChecks WhenStalled|Always` the checks are asynchronous and share the same
deadline: a command still queued then leaves its host pending, not failed, and
`WhenStalled` skips a host whose VM agent is not Ready or whose VM has an extension
operation in flight (it would queue behind it) and says so. Extension provisioning
and direct sensor health are different signals; earlier direct checks reported a
healthy sensor.

Inspect VM instance view, extension state and exact-ID Heartbeats read-only.
Do not cancel the update, remove/reinstall Defender, restart anything or infer
readiness from extension state in either direction.

## Arc reconnects after startup, but Windows Heartbeat is still pending

First inspect exact backing-VM power and Arc connection read-only. Overnight
auto-shutdown (the DevTest schedule, or governance automation on the
subscription, see the [runbook](runbook.md#5-park-and-wake-separate-disruptive-approval))
does not start hosts the next morning; a deallocated VM is not
proof of a broken Arc agent. Starting it needs explicit approval and a verified
existing outbound path, not an incidental repair.

During the approved eight-host rehearsal, Windows Arc connection returned before
fresh Heartbeats were queryable. Bounded read-only observation eventually verified
all eight expected Arc IDs and all 79 checks without restarting/reinstalling AMA.
Use `Test-ArcDemoReadiness.ps1` with the same target/skin and a bounded timeout;
retain pending status until new `_ResourceId`-matched telemetry is visible.
New ingestion of an old buffered record does not make its `TimeGenerated` fresh.
If the deadline expires, report the actual missing IDs and inspect evidence;
do not restart agents or substitute native-VM identities to manufacture success.

## A rapid wake reports a patch assessment already in progress

An earlier assessment can still be running when compute wakes again.
`OperationConflict` from assessment submission is recorded as
`already-in-progress`, with a warning; activation continues without retrying or
cancelling that operation. This is not assessment completion or full readiness.
Authentication, missing-resource and other submission errors still fail.

## Activation waits forever or reports success with missing hosts

Old lifecycle scripts compared counts, inferred Windows from `win-*`, ignored
timeout results and expected native Azure VMs to have Arc records. They could
also use only the newest empty fleet after an optional-workload-only deployment.
The maintained scripts require explicit subscription/tenant, retain per-workload
manifests, use actual VM OS metadata and compare exact IDs. Run read-only
`Test-ArcDemoReadiness.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -OutputFormat Json`.
Resolve its failed checks; do not add unrelated hosts to satisfy a count.
Do not delete subscription deployment history: missing/ambiguous inventory is an
activation error requiring reconciliation, not a silent "no VMs" success.
Parking instead uses actual compute in the explicit infra group.

## Workbook deployment succeeds but content verification fails

A plain ARM workbook GET can return metadata with empty `serializedData`.
That is not proof the deployment lost its queries. `Set-OperationalWorkbook.ps1`
requests the [full workbook content](https://learn.microsoft.com/rest/api/application-insights/workbooks/get)
with `canFetchContent=true` before comparing it with the deployed JSON. It uses
native REST so Windows CLI URL parsing does not split the query parameters.
Do not redeploy the whole lab or change telemetry collection for this symptom.

## Capacity workbook has Linux CPU but blank or thin memory or disk

Linux memory and disk come from four Linux AMA counters in the core DCR
(`Memory(*)\Available MBytes Memory`, `Memory(*)\% Used Memory`,
`Logical Disk(*)\% Free Space` and `Logical Disk(*)\Free Megabytes`, table `Perf`).
The earlier rule carried three placeholder names that Linux AMA never accepted
(`AvailableMemory`, `PercentUsedMemory`, `FreeSpacePercentage`), so those hosts
reported only CPU. If memory or disk still read as missing, confirm the rule holds
the four names and the Arc-ID association, then allow a few sampling intervals on a
running host. *Thin history* only means fewer observed hours than the
*Evidence needs* selector (24 by default); lower it to see the rows classified.
Pseudo mounts (snap, tmpfs, devices) are excluded by design.
Windows `_Total` disk is aggregate; per-volume evidence requires actual VM Insights
rows. More than 15 minutes stale or low elapsed-window coverage can also follow
parking; verify existing read-only readiness and timestamps, not an assumed agent
fault. Do not activate, repair or broaden collection just to fill a workbook.
Change the rule only by a targeted read-modify-write that keeps every other data
source, stream and association. See the [workbook reference](operational-workbooks.md).

## A parent shows insufficient evidence or the nested guest shows no telemetry

A declared Hyper-V parent reads *Insufficient evidence* (*Parent counters exclude
guest load*) by design: Microsoft documents that root-partition CPU counters do not
reflect physical CPU use, so a quiet parent is not headroom. Pressure on the parent
still counts, and parent and guest are never added. A declared guest reads *No
telemetry* until its own agent and DCR association deliver samples; Arc *Connected*
is evidence about the agent, not about telemetry. A guest missing from the roster is
not yet an Arc machine in the group: onboard it, then republish the workbook. Do not
change associations or collection from the workbook.

## Arc machine tags are missing or one tag holds the rest

**Symptom** — the Estate Overview's OS and environment filters, its Role and Tier columns and the
governance table are empty or wrong, and every Arc machine reads *(untagged)* in the Capacity roster.
An affected host keeps only `costcenter`, `env`, `owner` and `purpose`, and the value of `owner` holds
the rest (`demo purpose=arc-demo role=sql osType=Windows ...`). Readiness fails the required
`tags/<machine>` row and parity fails `fleet/<machine>/tags`.

**Cause** — an earlier Deploy set the tags with `az connectedmachine update --tags k=v k=v ...`. In
the `connectedmachine` extension 3.0.0 that option is shorthand syntax and folds every pair after the
first into the first key's value, and the step ran on every Deploy, so each rerun corrupted the tags
again while printing success. Deploy now merges them through the ARM tags API (`Set-DemoResourceTags`),
reads the result back and skips a host whose tags already match.

**Recovery** — rerun Deploy with the same skin; it writes only the tags that differ and recreates
nothing. A tag edit is a resource write, and on a Linux host a write can seed the Defender stall
described in [Linux ARM Updating while monitoring guest handlers are healthy](#linux-arm-updating-while-monitoring-guest-handlers-are-healthy),
so to repair one host without a redeploy merge just its tags (a Merge keeps every tag it does not name):

```powershell
Import-Module .\scripts\lib\Common.psm1
Initialize-DemoContext -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID>
Set-DemoResourceTags -ResourceId '/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/rg-<prefix>/providers/Microsoft.HybridCompute/machines/<machine>' `
    -Tags ([ordered]@{ owner = 'demo'; role = 'sql'; osType = 'Windows'; osTier = 'WS2022' })
```

The capacity and optimisation workbooks list the Arc machines and their tags as they were when they were
published, so a tag repair needs a republish of both (a separately approved step; see the
[runbook](runbook.md)).

## Linux Change Tracking missing despite healthy AMA

The previous deploy implementation installed CT via Arc while AGENTS required
the Azure VM path for this lab's unreliable Linux guest-extension stack.
Ordinary Arc CT support does not validate that stack on an Arc-enabled Azure VM.
The maintained path uses `Microsoft.Azure.ChangeTrackingAndInventory` /
`ChangeTracking-Linux` as a **VM extension**, retaining existing AMA and **Arc-ID**
DCR associations. Approved installation on the three Linux lab hosts verified
handler 2.42.0.0 guest success and fresh ConfigurationData/ConfigurationChange
records without restarting VMs. The handler remains auto-upgrade enabled.
See [Microsoft's supported CLI examples](https://learn.microsoft.com/azure/azure-change-tracking-inventory/change-tracking-inventory-support-matrix).

First inspect both extension surfaces and DCRAs read-only. Obtain scoped approval
before installation. Do not delete stuck Arc extensions, restart a VM or move
DCRAs incidentally. Provisioning success and data arrival are separate checks;
CT cycles/ingestion can lag substantially.

## Container App is healthy but readiness says pending

Healthy active revisions can report `RunningAtMaxScale` or `RunningAtMinScale`,
not only `Running`. The readiness check accepts these states. Compare a
timestamped app `runningStatus`, latest/latest-ready revision, active revision
`healthState`/`runningState` and `SIMULATE_CRASH` **without updating them**. A stale
snapshot or enum mismatch is not grounds to reset a workload fault.

## The Container Apps environment is slow or fails with `ManagedEnvironmentProvisioningError`

**Symptom** — a Deploy with Container Apps enabled spends 17-23 minutes on `cae-<prefix>`, which
shows `Waiting` for 20 minutes or more; or, in one observed run, the deployment ended `Failed` with
`ManagedEnvironmentProvisioningError: Fail to create managed environment because creation of the
managed cluster failed, please retry later.` Everything else (VMs, network, vault, monitoring)
was created; the fault app was not.

**Cause** — the environment is the slowest single resource in the estate, so a long `Waiting` is
normal and the console prints it as a running module. The error is a platform error the service
itself calls retryable: the identical template and region created the environment in the runs
before and after, the provider was registered and no leftover managed resource group or Service
Health event existed. No defect in this repo is known.

**Recovery** — confirm the state as in [a fresh Deploy failed part way](#a-fresh-deploy-failed-part-way),
then rerun the same Deploy command: it adopts the failed deployment's vault, reuses the saved
admin password and submits the template again. If it fails again on `cae-<prefix>`, check
Service Health, wait and retry; deleting only that environment is the next step, and it needs
the operator's approval (it holds nothing else and the fault app was never created). Do not
Remove the estate for this. To keep a failure here from stranding the base estate, build
the base first and add Container Apps as a second Deploy pass
([lifecycle](lifecycle.md#adding-an-optional-workload-to-a-running-estate)).

## Preflight or redeployment now refuses a previously tolerated state

Preflight no longer registers providers or skips RBAC for a supplied principal.
Missing providers, missing CLI extensions (`connectedmachine`, plus `containerapp`
for Container Apps, which is preview-only today and takes about 2 minutes to install), insufficient effective permissions, malformed skins,
SKU restrictions and insufficient quota terminate with instructions. Missing
providers and extensions are reported together, for example
`az extension add --name connectedmachine --yes`; preflight itself installs and
registers nothing.
Quota/listing checks are not capacity guarantees.
`Deploy-ArcDemo.ps1` does not reset SP credentials or generate a new password for
existing VMs. Old labs without the saved Key Vault secret need their **current**
password as `-AdminPassword` (SecureString), or the file an earlier run saved with
`-AdminPasswordPath`; obtain it from the operator and
do not rotate it as a shortcut. Arc onboarding needs no supplied secret: it adds
and removes its own one-day SP credential (see the next entry).
See [lifecycle semantics](lifecycle.md).
The [nested build](nested-sql-demo.md) is separate: it needs no vault and uses
the same one-day credential flow.

## Arc onboarding cannot add its one-day credential

Deploy and the nested build stop with `Could not add a one-day credential to the
onboarding application` when Graph refuses the new credential (for example
`Authorization_RequestDenied`). The signed-in operator must own the
`sp-<prefix>-onboard` application or hold an application administrator role.
Either fix that, or pass the application's current secret as `-OnboardingSecret`
(SecureString), which skips the one-day credential. The helper never resets or
reads existing credentials. A failed removal is reported with the new credential's
expiry (one day); it cannot outlive that.

Deploy also stops before onboarding if the Arc resource group does not exist, because
the `Azure Connected Machine Onboarding` role is granted at that group. A rebuilt
group has lost the previous assignment; the helper re-grants it and waits 90
seconds for propagation, so a retry after a failed first attempt needs no manual
role work.

## Parity reports a long-lived credential on the onboarding application

**Symptom** — `Test-ArcDemoParity.ps1` fails `tenant/no-long-lived-credentials` and names a credential such as `rbac until
<date>` on the `sp-<prefix>-onboard` application, while `tenant/no-residual-credentials` passes.

**Cause** — an older Deploy created the onboarding application with `az ad sp create-for-rbac`, which also adds a
one-year password credential that nothing removed. The build only ever mints one-day credentials; Deploy now removes the
creation-time credential once onboarding has used it. Nothing holds the old secret.

**What to do** — this is the owner's decision, not a repair step: no script deletes an existing credential, and
`Remove-ArcDemo.ps1 -RemoveOnboardingIdentity` removes only the service principal. With the owner's approval, delete
that one credential by its key ID from `az ad app credential list --id <appId>`:

```powershell
az ad app credential delete --id <appId> --key-id <keyId>
```

The next Deploy and nested build mint and remove their own one-day credentials as before. Until the owner decides, report the
failed row as known rather than clearing it another way.

## Activate rejects an unused alternative parent as outside the manifest

If a parked alternative SQL parent remains alongside the selected scratch parent,
Activate correctly refuses to guess its role. Set `operations.keepParkedVmNames`
in the private skin to its exact name, only when it is already deallocated and
not part of the active fleet. Activate leaves it parked and readiness checks it;
unknown, running or missing exclusions still fail explicitly. Do not add it to
the active manifest or boot its nested guest merely to clear the error.

The reverse failure, `Explicit keep-parked VM <name> must exist in <infra-rg> and be
deallocated`, means a listed VM was deleted (or is running). Remove deleted VMs
from `operations.keepParkedVmNames` in the private skin; keep a name there only
while that VM exists and is parked.

## Microsoft Graph calls fail with a continuous access evaluation challenge

**Symptom** — every `az ad ...` call (the preflight's signed-in-user lookup, the onboarding identity,
the nested build, inventory snapshots, `Prepare-NestedSqlParent.ps1`, `Remove-ArcDemo.ps1`) starts failing,
often an hour into a session, while ARM calls keep working:

```text
Continuous access evaluation resulted in challenge with result: InteractionRequired and code: TokenCreatedWithOutdatedPolicies
```

Repeated `az login` (even with the Graph scope) does not clear it.

**Cause** — the Azure CLI keeps reusing a cached CAE-capable Graph token that was minted before a
tenant policy event, and cannot answer the interactive challenge non-interactively.

**Fix** — The scripts now retry a Graph call that fails with exactly this challenge once with
`AZURE_IDENTITY_DISABLE_CP1=1` for that one child process (the CLI then requests a token without the CAE
capability), warn that they did, and keep doing so for later Graph calls in the process. A setting you made
yourself is never overridden. You can also set it for the whole shell before running a script or an `az`
call, which is the documented workaround and affects neither ARM calls nor the default subscription:

```powershell
$env:AZURE_IDENTITY_DISABLE_CP1 = '1'
```

The alternative is a fresh sign-in, `az logout` then `az login --tenant <TENANT>`. A new login can change the
CLI's default subscription; the scripts always pass the explicit subscription and refuse a directory call
when the CLI's default tenant differs from the requested one, so re-select the tenant and subscription
afterwards and never rely on the default.

`-DeployerPrincipalId` (and `deployerPrincipalId` in `build.json`) replaces only the preflight's signed-in-user
lookup. It bypasses no permission: the same Owner (or Contributor plus User Access Administrator) check runs
against that ID, so supply your own object ID, never someone else's. When Graph is the blocked service, read it
from the `oid` claim of your own ARM token, locally:

```powershell
$jwt = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$p = $jwt.Split('.')[1].Replace('-', '+').Replace('_', '/')
$p = $p.PadRight($p.Length + (4 - $p.Length % 4) % 4, '=')
([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json).oid
```

## Deploy finishes but says required readiness rows did not pass

**Symptom** — the last phase ends with `required infrastructure/monitor readiness rows did not pass:
heartbeat/<host> (pending), ...` (the rows are named; each is also printed as a warning).

**Cause** — Deploy validates what it built, read-only, for up to 20 minutes. `heartbeat/*` rows stay
`pending` while Azure Monitor Agent telemetry catches up (about 10 minutes, longer for Windows hosts); a
`fail` row is a real gap. The nested SQL guest is not part of this check: it is built after Deploy (wrapper
step P4), so its `nested/arc` row is left out here and is gated by P7. Before this was fixed, a skin with
`nestedSqlGuest` could never pass Deploy's last phase, which stopped the wrapper at P2 on a perfect deployment.

**Fix** — nothing was repaired or reset. Rerun `Test-ArcDemoReadiness.ps1 -DesiredState Active` (read-only)
until it exits 0 rather than redeploying.

## Deploy fails partway at the nested parent: `securityType` is not available

**Symptom** — most VMs, the network, the vault and the monitoring are created, then the
nested SQL parent's module fails:

```text
BadRequest ... The value 'Standard' is not available for property 'securityType' until the feature Microsoft.Compute/UseStandardSecurityType is registered
```

**Cause** — The nested SQL parent declares security type `Standard` (Hyper-V cannot run
under Trusted Launch) and Compute accepts it only on a subscription that has the
`Microsoft.Compute/UseStandardSecurityType` feature registered. Current preflight
(`Test-Prerequisites.ps1`, the build wrapper's P0 and Deploy) checks it read-only and stops
before any spend, so this only appears with an older checkout.

**Fix** — With separate approval, register the feature once, then refresh the provider (the
refresh is what propagates it; both took under a minute in the rebuild that found this):

```powershell
az feature register --subscription <SUB> --namespace Microsoft.Compute --name UseStandardSecurityType
az feature show --subscription <SUB> --namespace Microsoft.Compute --name UseStandardSecurityType --query properties.state -o tsv
az provider register --subscription <SUB> --namespace Microsoft.Compute --wait
```

Then rerun the same Deploy command.

## Deploy fails immediately with `SkuNotAvailable`

**Symptom** — `Deploy-ArcDemo.ps1` fails at the VM creation phase with:

```text
SkuNotAvailable: The requested VM size for resource 'Following SKUs have failed for Capacity Restrictions: Standard_B2as_v2' is currently not available in location 'australiaeast'.
```

**Cause** — Azure capacity restrictions on burstable B-series in AU regions, especially in MCAPS-style subscriptions.

**Fix** — Deploy now catches this (and `AllocationFailed`, `ZonalAllocationFailed`,
`OverconstrainedAllocationRequest` and quota errors) and prints the options with
the exact commands. It never switches VM size or region on its own: retry later
with the same command (it resumes when the first run saved its password with
`-AdminPasswordPath`, as the build wrapper does; see
[A fresh Deploy failed part way](#a-fresh-deploy-failed-part-way)), or choose another size/region explicitly for
a new lab. Inspect restrictions and quota in the confirmed target:

```powershell
az vm list-skus --subscription <SUB> -l australiaeast --size Standard_B2as_v2 --all -o table
az vm list-usage --subscription <SUB> -l australiaeast -o table
```

Choose a permitted SKU/region and review the matching Bicep preview. Neither an
unrestricted SKU listing nor `--validate` guarantees physical allocation. Do not
create/delete arbitrary probe resource groups in an in-use lab. The `list-skus`
command above takes 3-4 minutes with `--all`, and `list-usage` counters can lag for hours
after a Remove (a count of 2 to 6 vCPUs with no VMs left is stale, not a reason to stop).

## Capacity preflight says "Insufficient ... vCPU quota" with plenty of headroom

Azure CLI 2.91 returns vCPU usage as strings, so older checks computed
`'22' + 16 = '2216'` and failed as soon as any vCPU was in use (an empty
subscription passed by luck). The check now reads numbers, can add several VM sizes
of one family together (`Test-DemoComputeCapacity -Requirements`) and names the quota
it exceeded, for
example `standardBasv2Family vCPU quota ...: 90 in use + 16 needed ... limit of 100`.
Trust that message: request quota or reduce the fleet. A regional `cores` overflow
means the total across all VM families would exceed the regional limit. This check is
Deploy's first step, not part of `Test-Prerequisites` or the wrapper's P0; it takes about
4 minutes and prints a banner first. Usage counters can lag for hours after a Remove, so
compare a surprising number with `az vm list` before acting on it.

## A fresh Deploy after Remove complains about the canonical Key Vault

**Symptom** — `Canonical deployment-output vault is absent/ambiguous` right after
a full `Remove-ArcDemo.ps1`.

**Cause** — Old versions treated the retained subscription deployment record of the
removed estate as proof that its vault must exist. Current Deploy ignores a
manifest whose infra group no longer exists, prints a notice and builds a fresh
vault. If the message still appears, the infra group exists and does not contain
the vault the newest manifest names: review that group rather than deleting records.
`Remove-ArcDemo.ps1 -PruneDeploymentHistory` removes the stale records after a verified removal.

## Remove stops at the nested guest shutdown or the workspace comes back with old data

A blocked guest-stop Run Command no longer aborts removal: Remove waits at most ten
minutes, warns and continues, because the parent and guest are deleted with the
group. Separately, a deleted Log Analytics workspace is only soft-deleted for 14
days and re-creating the same name recovers it with its data. Use
`Remove-ArcDemo.ps1 -ForceDeleteWorkspace` (irreversible) before the group delete
when a clean workspace is wanted.

## The Key Vault is private-only and `az keyvault secret` is refused (`ForbiddenByConnection`)

**Symptom** — an older Deploy retried the first `vm-admin-password` write for about ten
minutes after Bicep succeeded and then failed, warning about "role propagation":

```text
(ForbiddenByConnection) Public network access is disabled and request is not from a trusted service nor via an approved private link.
```

The vault reads `publicNetworkAccess=Disabled` although Deploy asked for `Enabled`.

**Cause** — Not role propagation. A tenant or management-group policy with a `modify` effect on
`Microsoft.KeyVault/vaults/publicNetworkAccess` (in the rebuild that found this, a tenant-root
assignment) flips every new vault to private-only seconds after it is created; the vault's
activity log shows `Microsoft.Authorization/policies/modify/action`. The policy cannot be undone
from the demo, and a rebuild fails the same way. Only the data plane (`az keyvault secret
set/show` from a workstation) is blocked; Azure Resource Manager is not.

**Fix** — Current Deploy writes the secret through Azure Resource Manager
(`Microsoft.KeyVault/vaults/secrets`), warns once that a policy made the vault private-only and does not
retry what cannot clear. Nothing to do for a new build. Because the vault can then never be read from
a workstation, every later Deploy needs the current password from somewhere else: pass
`-AdminPasswordPath <private folder>\vm-admin-credential.clixml` (the build wrapper always does), which a
fresh build fills before any Azure write, or `-AdminPassword`. Do not open the vault, add network
exceptions or reset a VM password to get around this.

## A fresh Deploy failed part way

**Symptom** — the console ends with an error after some VMs, the vault or the monitoring were
created: a platform error, a lost connection (`ConnectionResetError`), a missing subscription feature, a
slow Container Apps environment. The estate is partial.

**Recovery** — Deploy submits the deployment without blocking and polls it, so a lost client
connection during the build no longer ends it (a reset while *submitting* is checked against
Azure before anything is resubmitted). A fresh Deploy saves the generated VM admin password before it changes anything,
when `-AdminPasswordPath` is given (the build wrapper's P2 always gives it), and a rerun reads it
back, so the same command resumes. Check what Azure has first:

```powershell
az deployment sub show --name <arc-demo-timestamp from the console log> --query "{state:properties.provisioningState,error:properties.error}" -o json
```

| The deployment is | Do |
| --- | --- |
| Not found (`DeploymentNotFound`) | Nothing was created; rerun the same command. |
| `Running` | Wait. Deploy refuses to start a second deployment over it (it would race the VM and vault creation). |
| `Failed` | Read `error` (and the troubleshooting entry that matches it), fix the cause, rerun the same command. Deploy adopts the vault named by its own failed deployment and reuses the saved password; it never adopts another vault. |
| `Succeeded` | Rerun the same command; it is a normal idempotent redeploy. |

If VMs exist and the saved file is missing (a build started without `-AdminPasswordPath` on an older
checkout), the password is unknown and routine redeploy must not generate or rotate one. The only
recovery that needs no credential change is `Remove-ArcDemo.ps1` for both groups and a fresh Deploy;
resetting the VM password is a separate approved credential change.

## What-if lists the Defender plan with `Delete properties.extensions`

**Symptom** — a manual `az deployment sub what-if` (or deployment) of
`bicep/main.bicep` shows `Microsoft.Security/pricings/VirtualMachines` as a Modify
with `Delete properties.extensions`.

**Cause** — The template's default `deployDefenderVmPlan=true` applies the Defender
for Servers module, which declares no `extensions`. On an enabled plan that would
remove settings such as AgentlessVmScanning. `Deploy-ArcDemo.ps1` reads the live
plan and passes `false` when it is already Standard, so its own what-if lists no
Defender change.

**Fix** — Deploy through `Deploy-ArcDemo.ps1`, or pass `deployDefenderVmPlan=false`
when using the template directly. Do not edit the plan or its extensions to quiet the
preview. If Deploy stops with `Cannot read the Defender for Servers plan tier`, the
plan read was empty or returned an unknown tier: inspect it with
`az security pricing show --name VirtualMachines`.

## Preparing the nested SQL parent stops

`Prepare-NestedSqlParent.ps1` stops at the first failing phase, keeps what it
finished and says why. Fix the cause and rerun: every phase checks first, so a
rerun repeats only what is missing. It never tries another size, region, disk or
drive letter for you.

| Symptom | Cause and fix |
| --- | --- |
| `The lab is not Active (no NAT gateway on snet-vms)` | Starting compute needs explicit outbound networking. Run the approved Activate first. |
| `Only Standard_D4s_v5 is evidenced for nested virtualization` | The skin declares another size. Use a nested-capable size without a temp disk (the data volume must be `D:`) and add `-AllowUntestedSize`. |
| `Resize to ... failed` | Usually no capacity for the size in that region. The parent stays deallocated at its old size; retry later or request quota. No other size is tried. Restore it with the approved lifecycle if the demo needs it now. |
| `A nested guest is running; stop it gracefully` | Size and HyperV restart the parent. Stop the guest with the pair-only state helper first. |
| `LUN 0 already holds ...` or `Disk ... already exists but is attached elsewhere or differs` | Prepare never reuses, resizes, converts or moves a disk. Declare the existing disk in the skin or remove the stray disk deliberately. |
| `Drive D: is already used by another volume` or `Refusing to initialise a data disk that already has partitions` | Volume moves the empty virtual DVD-ROM that a size without a temp disk leaves on `D:` to `Z:` (seen on a fresh `Standard_D4s_v5`), but will not touch any other `D:` (a temp disk on a `d` size, a data volume, a DVD-ROM that holds a disc) or a disk that is not blank. Inspect the VM and decide deliberately. |
| `Hyper-V is not running after the restart` | The size or security type blocks nested virtualization; Trusted Launch is not supported, the parent must be `Standard`. Check both, then rerun `-Phase HyperV`. |
| `Cannot connect to CIM server. A system shutdown is in progress.` (or another guest error right after the restart) | Windows restarted itself a second time shortly after the first boot (servicing finishing after the role install) while Arc already read `Connected`. HyperV now inspects again until two inspections a minute apart both find Hyper-V ready (about 10 minutes at most) and only then fails with the guest's own error. If you still see it, wait two minutes and rerun `-Phase HyperV`: it reports the phase satisfied. |
| `Guest prefix ... overlaps ...`, `An existing NAT conflicts ...` or `Switch ... exists with type ...` | `172.31.240.0/24` collides with the Azure address space, a route or a different switch or NAT. Pass other `-GuestNetworkPrefix`, `-GatewayAddress` and `-GuestAddress` and use the same values in the build. |
| Pinned-size or hash errors while staging media | See [Media staging stops on a size or hash mismatch](#media-staging-stops-on-a-size-or-hash-mismatch). |
| `Verify failed: ...` | The result's `checks` name each failing check. Run the matching `-Phase`, then Verify again. Verify never starts a parked parent; run Activate first. |
| Verify takes about five minutes after a start | It hashes both ISOs (about 6 GiB) read cold from the data disk, observed at 4m45s on a `Standard_D4s_v5` with a `StandardSSD_LRS` disk against about one minute when the files are cached. It is not stuck; the guest call allows 15 minutes (`-TimeoutSeconds`). |

## Deploy refuses a retained VM's size or data disk

**Symptom** — `Deploy-ArcDemo.ps1` stops before any preview with
`VM <name> is Standard_D4s_v5 but this deployment requests Standard_B2as_v2`,
`has data disk ... that this deployment does not declare, so it would be detached`
or `Data disk ... differs from its declaration`.

**Cause** — Deployment never resizes a VM or detaches, resizes or converts a
data disk it did not create. The nested SQL parent runs a virtualization-capable
size with a data disk, so a deployment that declares the shared size (or no disk)
for it would revert the size and drop the disk.

**Fix** — Declare what the VM already has. For the nested parent, enable
`nestedSqlGuest` in the skin (it declares `Standard_D4s_v5` and a 128 GiB data
disk; override with `parentVmSize`, `parentDataDiskGb`,
`parentDataDiskStorageAccountType` when the retained VM differs, for example a
retained `Standard_LRS` disk). For any other entry add `vmSize` and `dataDisks`
to its [fleet entry](legacy-os-fleet.md#per-entry-size-and-data-disks). A real
size change is a separate approved resize with the VM deallocated, not a deploy.

## Clean deploy fails while creating DCRs with missing Log Analytics tables

**Symptom** — A first deployment into a clean subscription/prefix fails during
Data Collection Rule creation with a `BadRequest`, `table not found`, or stream
mapping error for `Perf`, `Event`, `Syslog`, `InsightsMetrics`, or
`ConfigurationData`.

**Cause** — A brand-new Log Analytics workspace and the VM Insights / Change
Tracking solutions can report `Succeeded` before their standard tables are
queryable by the DCR API.

**Fix** — Current `Deploy-ArcDemo.ps1` avoids the race by keeping DCRs out of
the initial Bicep deployment, waiting for the required tables, and then
upserting `dcr-arc-demo`, `dcr-vminsights`, and `dcr-changetracking` with
bounded retries. Re-run the deploy script; the DCR names and DCRA names are
deterministic, so reruns update existing resources instead of duplicating them.

## Arc machines show `Disconnected` shortly after deploy

**Symptom** — Arc Connected immediately after onboarding, then `Disconnected` after the first overnight auto-shutdown.

**Cause** — Earlier deployments relied on implicit default outbound rather than an explicit outbound path. Do not assume that path survives a deallocate/start cycle.

**Fix** — Fresh deployment now creates a **NAT Gateway** before compute/extension provisioning. Activation recreates it before starting parked VMs. For an older lab missing NAT, after approving activation, run:

```powershell
.\scripts\Activate-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath <PRIVATE_SKIN_PATH>
```

## No Heartbeat in Log Analytics for Linux hosts

**Symptom** — Windows hosts are beating; Linux hosts show 0 records in `Heartbeat`.

**Cause** — One of two:

1. The Linux Arc GC extension stack is broken on Ubuntu 22.04 with `MSFT_ARC_TEST=true` (a suspected contributor is the agent daemons missing that variable on hosts onboarded by an older Deploy; see [Linux Arc extensions and assessments](#linux-arc-extensions-and-assessments-stay-creating-after-every-wake)). The repo installs AMA via the Azure VM extension path on Linux, which sidesteps this. If you reverted that and installed via the Arc extension, you'll hit this.
2. The DCR association is on the **Azure VM** resource ID instead of the **Arc** resource ID. The Linux AMA detects Arc and pulls config from Arc IMDS, which only sees DCRA's attached to the Arc resource.

**Fix** — Inspect:

```powershell
# Should show AMA on the Azure VM ext list (Linux)
az vm extension list --subscription <SUB> -g rg-arc-demo-infra --vm-name lnx-app-01

# Linux has core + CT DCRAs on the Arc resource; Linux VMI map is disabled.
az monitor data-collection rule association list --subscription <SUB> `
  --resource "/subscriptions/<SUB>/resourceGroups/rg-arc-demo/providers/Microsoft.HybridCompute/machines/lnx-app-01"
```

If a DCRA is wrongly attached to the backing Azure VM, obtain approval for the
exact association repair before changing/deleting anything. The intended Arc
association payload is:

```powershell
$sub = '<SUB>'
Import-Module .\scripts\lib\Common.psm1 -Force
Initialize-DemoContext -SubscriptionId $sub -TenantId <TENANT>
$arcId = "/subscriptions/$sub/resourceGroups/rg-arc-demo/providers/Microsoft.HybridCompute/machines/lnx-app-01"
$dcrId = "/subscriptions/$sub/resourceGroups/rg-arc-demo/providers/Microsoft.Insights/dataCollectionRules/dcr-arc-demo"
$body = @{ properties = @{ dataCollectionRuleId = $dcrId } }
Invoke-AzRest -Method Put -Body $body `
  -Url "https://management.azure.com$arcId/providers/Microsoft.Insights/dataCollectionRuleAssociations/dcra-core-lnx-app-01?api-version=2022-06-01"
```

Do not assume a restart is needed. Only if separately approved diagnostics
require an AMA service restart, use the checked, file-backed guest helper:

```powershell
$machine = @{ Name = 'lnx-app-01'; OsType = 'Linux'; Id = "/subscriptions/$sub/resourceGroups/rg-arc-demo-infra/providers/Microsoft.Compute/virtualMachines/lnx-app-01" }
Invoke-DemoGuestCommand -Machine $machine -Script 'set -e; sudo systemctl restart azuremonitoragent; echo ARC_DEMO_OK'
```

Use bounded exact-ID readiness afterward; do not promise a fixed five-minute recovery.

## Linux Arc extensions and assessments stay `Creating` after every wake

**Symptom** - On the Linux hosts the Arc extension manager keeps exiting and
restarting, so Arc extensions and Update Manager assessments stay
`Creating`/`InProgress` after each wake while Heartbeats are fine.

**Suspected cause (confirm in the live proof)** - Arc on an Azure VM needs
`MSFT_ARC_TEST=true` in the environment of the agent **daemons** as well as for
`azcmagent connect` ([Learn](https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine)).
Onboarding set it for `connect` only, so `extd` (extension manager) and `gcad` (guest
configuration) ran without it, and a manual `systemctl set-environment` does not
survive the reboot that every wake involves.

**Fix** - Deploy's Linux onboarding (`New-DemoArcLinuxOnboardScript` in
`scripts/lib/Common.psm1`) now writes a persistent systemd drop-in,
`/etc/systemd/system/<unit>.service.d/msft-arc-test.conf` with
`Environment=MSFT_ARC_TEST=true`, for `himdsd`, `extd` and `gcad` before it connects,
runs `systemctl set-environment`, and restarts `extd`/`gcad` afterwards (a failed
restart only warns). Pester renders the script and runs `bash -n`; it has **not** run
on a Linux host yet. **To validate in the live proof**, after the first Linux
onboarding `systemctl show himdsd extd gcad -p Id -p Environment -p NRestarts` should
show the variable with a steady restart count, and Arc extensions and assessments
should reach `Succeeded` after a wake. Keep AMA and Change Tracking on the VM
extension path either way.

**Limit: hosts onboarded by an older Deploy** - Deploy onboards only machines that are
not Arc-connected yet, and Activate runs no guest commands (Run Command queues behind
VM extension updates and can stall a wake), so earlier hosts keep the old services.
Rebuild the host, or after separate approval run the same idempotent step once on each:

```powershell
Import-Module .\scripts\lib\Common.psm1 -Force
$machine = @{ Name = 'lnx-app-01'; OsType = 'Linux'; Id = "/subscriptions/<SUB>/resourceGroups/rg-arc-demo-infra/providers/Microsoft.Compute/virtualMachines/lnx-app-01" }
Invoke-DemoGuestCommand -Machine $machine -Script ((Get-DemoArcTestServiceEnvScript) + "`nsudo systemctl restart extd gcad`necho ARC_DEMO_OK")
```

## Update Manager shows no update data after activation

**Symptom** - Azure Update Manager shows no update data, or Linux Arc machines
show `LinuxOsUpdateExtension` stuck in `Creating` or `Deleting`.

**Cause** - Periodic assessment only fetches data every 24 hours. The activation
script submits an on-demand assessment, but Update Manager creates temporary OS
update extensions and the portal data is asynchronous. In the current lab,
Windows assessment results complete reliably first; Linux extension provisioning
can lag, and on a Linux host onboarded before the `MSFT_ARC_TEST` service drop-ins
it can stall at every wake (see
[Linux Arc extensions and assessments stay `Creating`](#linux-arc-extensions-and-assessments-stay-creating-after-every-wake)).

**Fix** - First confirm the activation script submitted assessments:

```powershell
$start = (Get-Date).AddHours(-2).ToString('o')
az monitor activity-log list --subscription <SUB> -g rg-arc-demo --start-time $start `
  --query "[?operationName.value=='Microsoft.HybridCompute/machines/assessPatches/action'].{time:eventTimestamp,status:status.value,resource:resourceId}" `
  -o table
```

Then inspect the update extension instance view:

```powershell
foreach ($name in az connectedmachine list --subscription <SUB> -g rg-arc-demo --query "[].name" -o tsv) {
  $m = az connectedmachine show --subscription <SUB> -g rg-arc-demo -n $name --expand instanceView -o json | ConvertFrom-Json
  $ext = @($m.resources | Where-Object { $_.name -in @('WindowsOsUpdateExtension','LinuxOsUpdateExtension') }) | Select-Object -First 1
  [pscustomobject]@{
    Name = $name
    Extension = $ext.name
    ProvisioningState = $ext.properties.provisioningState
    Message = $ext.properties.instanceView.status.message
  }
}
```

For the live demo, use the Windows assessment rows as the reliable proof point
and state that Linux assessment data is still processing if the Linux extension
has not reached `Succeeded`.

## `az` commands fail with `AuthorizationFailed` against the *wrong* subscription

**Symptom** — All your `az` commands suddenly start returning `AuthorizationFailed` against a sub ID you don't recognise.

**Cause** — When the CLI token expires and you're signed into multiple tenants, `az account show` silently falls back to a default subscription that *isn't* the demo target.

**Fix** — Always start a session with:

```powershell
az account show --subscription <SUB> --query "{id:id,tenantId:tenantId,user:user.name}" -o table
```

Confirm the tenant as well as the subscription. `Test-Prerequisites.ps1` and
lifecycle scripts verify the explicit target without changing CLI defaults.
Tenant-scoped directory commands are the exception to `--subscription`: see the
directory guard above; mismatches stop rather than silently switch accounts.

## `az rest` 400/500s with weird URL parsing errors

**Symptom** — `az rest --url '...?api-version=...'` fails with errors like `?api-version was unexpected at this time` or `unrecognized arguments: ?api-version=...`.

**Cause** — On Windows, `az` shells through `cmd.exe`, which treats `?` as a wildcard and `()` as command grouping. URLs containing both — especially the OMS Solutions API (`solutions/VMInsights(law-name)?...`) — get mangled before reaching the API.

**Fix** — Use PowerShell's native `Invoke-RestMethod` with an `az`-issued bearer token instead. The `Invoke-AzRest` helper in `scripts/lib/Common.psm1` does this for you. Never use `az rest` for those URLs.

## `az policy assignment create` throws a Python traceback

**Symptom** — `az policy assignment create --policy-set-definition ...` returns an `AttributeError: 'NoneType' object has no attribute 'get'` or `'_data'`.

**Cause** — CLI 2.85 bug specifically with built-in policy *set* definitions on subscription scope.

**Fix** — Use `Invoke-RestMethod` PUT against the policyAssignments REST endpoint directly. The Bicep template in this repo handles this declaratively; if you're tweaking outside the template, the helper pattern is in `Deploy-ArcDemo.ps1`.

## Real SQL workload has no Arc SQL or BPA experience

The [optional workload](sql-engine-workload.md) demonstrates an actual SQL engine,
orders database and transaction-derived events, not Arc SQL registration or BPA.
SQL Server in an Azure VM is not a supported Arc SQL validation target; see
the [support decision](sql-arc-spike.md). Missing Arc SQL/BPA content is not a
reason to install its extension, change licence metadata or promise that waiting
will enable it. Genuine Arc SQL features need a separately approved supported
non-Azure host. Any pre-existing extension needs reviewed diagnosis, not automatic
removal or reconfiguration.

## SQL-only block is effective but two SQL-related extension rows appear

Observed after real engine installation: `WindowsAgent.SqlServer` was Failed
with an explicit local-blocklist error, while `MicrosoftDefenderForSQL` was
Succeeded. The former is a blocked ARM operation, not a successful guest Arc SQL
installation. The latter is a separate security extension: activity claims and
a correlated DeployIfNotExists deployment identified an inherited subscription
security assignment acting on `mssqlDiscovered=true`.

Inspect exact publisher/type/state/error, policy assignment/definition and
available activity evidence read-only. ARM-shaped extension responses expose
metadata under `.properties`; missing flattened fields are not absence.
An empty policy-state query does not overturn an actual policy deployment.
Do not automatically delete the failed row, uninstall/block Defender, alter
discovery or disable a plan to clear drift. A separately approved normal delete
of only the Failed Arc SQL row can remain incomplete while disconnected; stop
without forcing/replaying it, then inspect after separately approved activation.
Retain required security and obtain policy-owner
review if an engine-only exception is genuinely necessary. The Arc SQL opt-out
does not exempt Defender; Succeeded with disconnected/empty sensor status does
not establish protection or billing. See the [engine-only prerequisites](sql-engine-workload.md#approval-fit-and-media).

If Arc later reports Disconnected, inspect the exact backing VM power state
before diagnosing an agent failure. A deallocated VM cannot provide fresh SQL
or guest telemetry proof; earlier successful installation/Status evidence is
historical, not permission to activate, reinstall or repair it.

## SQL is queryable after wake but the worker is Ready with stale commits

Observed after normal Arc activation: engine/database queries worked, but
SQL Status remained pending with the enabled task Ready and only pre-parking
commits. The boot-triggered task's LastTaskResult was 1; its LastRunTime preceded
SQL's ready-for-client-connections event by about 151 seconds. This supports a
startup-order race, not a proven SQL installation or data failure. The exact
task exception was unavailable because its Operational log was disabled;
do not enable that log or invent an exception during read-only diagnosis.

Inspect the owned task action/trigger/settings, LastTaskResult/LastRunTime,
engine service, actual SQL readiness events and owned `6000`/`6200` events.
The originally installed worker checked engine/database before its
transaction-loop catch, so absence of `6200` did not prove a successful start.
The updated source waits within a 600-second startup budget and emits terminal
`6200` with its failure phase; it does not retry ownership/schema/authentication
failures. Scheduler restart settings are not evidence that a retry succeeded.

Do not silently start/reset the worker as readiness or activation preparation.
After diagnosis and separate scoped approval, the owned helper's `-Action Start`
can start that task without SQL restart or installer replay; require subsequent
fresh Status pass and actual commit evidence. Updating an installed worker is a separate operation; see
[updating an existing worker](sql-engine-workload.md#updating-an-existing-owned-worker).

## Compliance scorecards (MCSB/NIST) are empty

**Symptom** — Policy assignments exist, but the **Regulatory compliance** page
in Defender for Cloud is blank.

**Timing boundary** - An assignment starts an asynchronous evaluation; there is
no guaranteed completion deadline. Standard reevaluation runs every 24 hours.
A blank Defender page is not proof of one specific root cause: check scope,
permissions, assignment and available evaluation results separately.

**First check** - Read **Policy** > **Compliance** in the confirmed scope.
See [current evaluation and compliance guidance](https://learn.microsoft.com/azure/governance/policy/how-to/get-compliance-data).
Do not promise a score during a short rehearsal. A separately approved
evaluation trigger can request a new scan:

```powershell
az policy state trigger-scan --subscription <SUB> --resource-group rg-arc-demo
```

The scan remains asynchronous with no fixed demo-time completion guarantee.

## Hibernation blocked by unrelated preflight or monitoring health

**Observed** - An added operator wrapper required deployment Graph/Owner checks,
a historical whole-group index match, and assumed attached disks must report
`Attached`. Those were wrapper defects, not requirements of the normal parking
script. A deallocated VM can have an attached disk reported as `Reserved`.
Generic extension indexes also differed from exact child GET results; enumeration
is not proof of existence, repair or health. Do not retry/recreate extensions to
make an old index match.

Use the normal lifecycle `-WhatIf` path, not `Test-Prerequisites.ps1` (deployment
only). Wrong context or denied/unknown compute reads still fail. Parking warns
manifest/skin/OS drift rather than requiring reconciliation first; foreign/shared
networking skips only network cleanup. Activation remains strict.

The old parked readiness also required healthy extensions/DCRAs after compute
was already stopped. Hibernated now inspects compute and non-required network
cost facts only, not retained monitoring health. A red network diagnostic does
not mean compute is active; an actual inspection error still fails. Recheck
retained monitoring before the next rehearsal, not during parking. On partial network
removal, retry the same script without waking or redeploying the stopped lab.
For full ACA history use revision `list --all`; default listing is active-only.
New source behavior is locally mocked, not a new live-lifecycle proof.

## Hibernate seems to skip the NAT GW delete

**Symptom** — Hibernate completes, but retained-service charges exceed an old estimate.

**Possible cause** - Other NAT GWs/public IPs, disks, enabled alert evaluations
or other retained services may still bill. A higher charge alone does not prove
that the expected gateway survived.

**Fix** — Check:

```powershell
az network nat gateway list --subscription <SUB> -g rg-arc-demo-infra -o table
az network public-ip list --subscription <SUB> -g rg-arc-demo-infra -o table
```

The script only deletes `natgw-<prefix>` and `pip-natgw-<prefix>` in the retained
infra group: defaults are `natgw-arc-demo` and `pip-natgw-arc-demo`. It first
verifies compute is parked and refuses to detach an unexpected subnet gateway.
Do not delete other networking as a cost shortcut; inspect its owner/scope.
An absent or foreign VM/manifest is an error, not permission for teardown.

## Cost is higher than expected

See [`cost.md`](cost.md) for the full breakdown by state. The most common surprises:

- **Defender for Servers Plan 2** uses published server/month pricing with applicable usage metering. Check the selected plan and actual billed coverage; VM deallocation is not a blanket promise of no Defender charges.
- **NAT Gateway/PIP** continue billing until removed. Successful hibernation verifies their absence.
- **Log Analytics** has ingestion and retention charges. Heavy debugging can increase ingestion; use current regional pricing and the workspace's actual usage, not an old hard-coded unit rate.

## "AGENTS.md says X, but the script does Y"

If [`AGENTS.md`](../AGENTS.md), a procedure and the actual script conflict,
stop before mutation and reconcile the discrepancy against code, current
supported behavior and approved scope. Do not bypass a safety rule merely
because a script permits an action. Update the affected canonical document
and agent guidance together.

## Deployment refuses an existing OS disk tier mismatch

The requested `OsDiskStorageAccountType` differs from a targeted retained OS
disk. Select its current tier using the CLI input or private
`compute.osDiskStorageAccountType`; an existing HDD lab needs explicit
`Standard_LRS`, while new OS disks default to `StandardSSD_LRS`.
Do not bypass the check or run an implicit conversion. An approved disk-tier
migration needs a maintenance window with stop/deallocate/restart; HDD OS
support retires on 8 September 2028. See [cost.md](cost.md).
