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

A nonempty `PendingFileRenameOperations` value was observed during an approved
SQL preflight even though the other checked reboot flags were clear.
That observation does not identify the owning package, prove an active installer
or authorize a reboot. The [real SQL helper](sql-engine-workload.md) fails closed
before installation; it never deletes the flag or skips setup checks.
Keep the running lab unchanged. Obtain separate scope for any deeper diagnosis
and approval for an appropriate reboot/repair before retrying installation.

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
Succeeded and data continues to arrive. Readiness must remain pending, not be
forced green. A missing MDE status file is not proof of working endpoint protection.
Preserve healthy AMA/CT and DCRAs; agree a targeted recovery before retrying MDE or
restarting anything. No reinstall/restart is part of read-only rehearsal preflight.

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

**Fix** - Activation checks Windows Arc AMA through `MonAgentCore`, as described
in [Microsoft's Windows Arc troubleshooting guidance](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-troubleshoot-windows-arc),
and restarts only real required services on newly started/disconnected hosts.
Already-running hosts receive read-only guest health checks on a retry. Missing
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

Activation now submits host checks concurrently and waits up to ten minutes for
Windows AMA, with job progress. Required Arc/Linux services must still be healthy.
An AMA deadline emits the explicit pending marker and records that host as
pending in `-ResultPath`; it does not restart/reinstall the agent. Final readiness
reports telemetry lag separately. If only Heartbeat is pending, activation exits
0 with pending evidence and a re-check message. Poll read-only readiness before
presenting or the combined incident offer; report pending if it does not converge.
Do not turn an auth failure, unhealthy service or failed extension into telemetry
lag. Microsoft documents both the
[MonAgentCore process and a further Heartbeat wait](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-troubleshoot-windows-arc#basic-troubleshooting-steps-installation-agent-not-running-configuration-issues);
the ten-minute budget is this repo's policy, not a service SLA.

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

## Arc reconnects after startup, but Windows Heartbeat is still pending

First inspect exact backing-VM power and Arc connection read-only. Overnight
auto-shutdown does not start hosts the next morning; a deallocated VM is not
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

## Capacity workbook has Linux CPU but blank memory or disk

The inspected existing demo stream contained Linux total CPU but no matching
Linux memory/disk `Perf` or VM Insights samples. Configured DCR counters alone
are not evidence they have arrived. The optional workbooks retain nulls and
missing-data warnings rather than deriving zero or safe sizing from CPU.
Windows `_Total` disk evidence is aggregate; per-volume evidence requires actual
VM Insights rows. More than 15 minutes stale or low elapsed-window coverage can
also follow parking; verify existing read-only readiness and timestamps, not an
assumed agent fault. Do not activate, repair or broaden collection just to fill
a workbook. See the [coverage rules](runbook.md#optional-capacity-and-optimisation-workbooks).

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

## Preflight or redeployment now refuses a previously tolerated state

Preflight no longer registers providers or skips RBAC for a supplied principal.
Missing providers, insufficient effective permissions, malformed skins,
SKU restrictions and insufficient quota terminate with instructions.
Quota/listing checks are not capacity guarantees.
Routine redeployment does not reset SP credentials or generate a new password for
existing VMs. Old labs without the saved Key Vault secret need their **current**
password as `-AdminPassword` (SecureString); an existing SP needed for new
onboarding needs `-OnboardingSecret`. Obtain the current values from the operator;
do not rotate them as a shortcut. See [lifecycle semantics](lifecycle.md).

## Deploy fails immediately with `SkuNotAvailable`

**Symptom** — `Deploy-ArcDemo.ps1` fails at the VM creation phase with:

```text
SkuNotAvailable: The requested VM size for resource 'Following SKUs have failed for Capacity Restrictions: Standard_B2as_v2' is currently not available in location 'australiaeast'.
```

**Cause** — Azure capacity restrictions on burstable B-series in AU regions, especially in MCAPS-style subscriptions.

**Fix** — Inspect restrictions and quota in the confirmed target:

```powershell
az vm list-skus --subscription <SUB> -l australiaeast --size Standard_B2as_v2 --all -o table
az vm list-usage --subscription <SUB> -l australiaeast -o table
```

Choose a permitted SKU/region and review the matching Bicep preview. Neither an
unrestricted SKU listing nor `--validate` guarantees physical allocation. Do not
create/delete arbitrary probe resource groups in an in-use lab.

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

1. The Linux Arc GC extension stack is broken on Ubuntu 22.04 with `MSFT_ARC_TEST=true`. The repo installs AMA via the Azure VM extension path on Linux, which sidesteps this. If you reverted that and installed via the Arc extension, you'll hit this.
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

## Update Manager shows no update data after activation

**Symptom** - Azure Update Manager shows no update data, or Linux Arc machines
show `LinuxOsUpdateExtension` stuck in `Creating` or `Deleting`.

**Cause** - Periodic assessment only fetches data every 24 hours. The activation
script submits an on-demand assessment, but Update Manager creates temporary OS
update extensions and the portal data is asynchronous. In the current lab,
Windows assessment results complete reliably first; Linux extension provisioning
can lag.

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
not establish protection or billing. See the [automatic-extension boundary](sql-engine-workload.md#automatic-extension-attempts-and-inherited-security).

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
fresh Status pass and actual commit evidence. Deploying the startup-order fix
to an installed worker needs the [reviewed update and rollback procedure](sql-engine-workload.md#updating-an-existing-owned-worker),
not an unreviewed overwrite that bypasses the source-hash/manifest contract.

## Worker migration stops with a `File.Replace` path error

Observed on guest Windows PowerShell 5: passing a null backup argument to
`File.Replace` produced "The path is not of a legal form" before replacement;
the same call also prevented the initial file rollback. Inspect the journal
and exact installed/backup hashes read-only before acting. In the observed
case both old files were unchanged and the owned task was stopped/disabled;
verified task-state-only recovery was sufficient, not another file overwrite.

Use explicit unique backup paths and verify displaced bytes. Test both a full
replacement/rollback and a real second-file sharing failure on local Windows
PowerShell 5. Unknown hashes or incomplete state must leave the task stopped;
do not force restoration or replay the failed migration.

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

## Private initializer reports another endpoint when the vault connection collection is null

The original initializer counted a null `privateEndpointConnections` pipeline
entry as a conflicting endpoint. An exact successful vault management GET can
legitimately return null for this optional collection. The corrected guard
filters null entries only; it still rejects foreign and malformed nonnull
connections. Local regressions cover all three cases and an empty collection.
This fix does not waive private endpoint ownership or private DNS checks.

Use the maintained initializer's read-only WhatIf with the same private setup
inputs. Do not remove real endpoint connections or treat a failed preview as
initialization permission. This is separate private-vault setup, not a nested
SQL build or lifecycle step.
