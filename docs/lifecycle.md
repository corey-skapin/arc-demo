# Demo lifecycle and readiness contract

**Operator/integrator reference.** For presenting without changing the lab, use
[the docs index](README.md) and [the presenter guide](runsheet.md).

This is a deliberately un-hardened, single-region demo, not a production
reference. The maintained entry points are the PowerShell scripts. Always pass
the **confirmed** subscription and tenant at runtime; neither belongs in a skin.
Use the same skin/prefix throughout. CLI defaults are not changed by the scripts.

## Supported operations

There are three desired states: **Active**, **Hibernated**, **Removed**.
`Ready` remains an alias for Active and the compatibility default. Pending/error
describes an unfinished transition, not a fourth state. Hibernation deallocates
VM hardware while preserving VM definitions, system-assigned identities, disks
and NICs. Deleting VM definitions would add reconstruction/identity risk without
further pay-as-you-go VM compute savings; this is not Azure RAM hibernation.
See [VM billing states](https://learn.microsoft.com/azure/virtual-machines/states-billing)
and [managed identity lifecycle](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview).

```powershell
$target = @{ SubscriptionId = '<SUB>'; TenantId = '<TENANT>'; SkinPath = '<PRIVATE_SKIN_PATH>' }
.\scripts\Test-Prerequisites.ps1 @target
.\scripts\Deploy-ArcDemo.ps1 @target -AdminEmail <EMAIL> -WhatIf
.\scripts\Test-ArcDemoReadiness.ps1 @target -DesiredState Ready -OutputFormat Json

# Disruptive: run only when the operator explicitly asks to park the demo.
.\scripts\Hibernate-ArcDemo.ps1 @target -WhatIf
.\scripts\Hibernate-ArcDemo.ps1 @target
.\scripts\Test-ArcDemoReadiness.ps1 @target -DesiredState Hibernated
.\scripts\Activate-ArcDemo.ps1 @target -WhatIf
.\scripts\Activate-ArcDemo.ps1 @target

# Permanent removal: separate, explicit operator approval.
.\scripts\Remove-ArcDemo.ps1 @target -WhatIf
.\scripts\Remove-ArcDemo.ps1 @target
.\scripts\Test-ArcDemoReadiness.ps1 @target -DesiredState Removed -OutputFormat Json
```

**Deployment** preflight is **read-only**: tooling, explicit context, effective inherited/group
Owner (or Contributor + User Access Administrator), and needed provider
registrations. Supplying a deployer principal ID does not bypass RBAC checks.
Missing registrations must be approved and registered separately. Baseline
providers include KeyVault, DevTestLab and Consumption. Optional Container Apps
requires Microsoft.App and the `containerapp` CLI extension; AKS additionally needs
ContainerService, ManagedIdentity, Resources, Storage and ContainerInstance for its
deployment script. A nested SQL parent (security type `Standard`) also needs the
subscription feature `Microsoft.Compute/UseStandardSecurityType`, registered by an
authorized operator once ([nested-sql-demo.md](nested-sql-demo.md#prepare-the-parent)).
`Test-Prerequisites.ps1 @target`, Deploy and the build wrapper's
P0 all read the same set for the skin's workload toggles.
The retired mixed SQL path no longer requests AzureArcData registration;
optional real SQL preparation does not enable Arc SQL.
The genuine nested guest uses its separate explicit extension helper.

Parking/waking/removal does **not** invoke that deployment Graph/Owner/provider/
capacity gate. Use the normal explicit context, retained workload inventory and
`-WhatIf` path; a genuine ARM authorization failure still stops the operation.
Before wake writes, exact subnet/NAT/PIP GETs refuse a foreign NAT,
another attached subnet/public IP/prefix, or a PIP bound to another resource.
Hibernate parks compute first; these same conflicts skip only network cleanup,
with a loud warning and retained-network cost diagnostics.
These narrow sharing guards replace neither normal authorization nor ownership
review. Do not compare whole resource-group counts or historical generic
extension indexes as a lifecycle gate. Optional identity removal checks directory
ownership/access before any removal writes, including on its preview.

Deployment checks the requested VM SKU's location restrictions and regional/family
vCPU quotas. These checks **do not prove spare physical capacity**; even ARM
validation/what-if cannot guarantee allocation. Do not create throwaway probes in
an arbitrary subscription. AKS node capacity is additional to backing VMs.

`-WhatIf` does not register providers, switch the CLI default subscription, reset
credentials, repair resources or run guest commands. Deployment preview uses
ARM what-if and a temporary parameter file removed in `finally`.

Deploy reads the live Defender for Servers plan (`az security pricing show`,
read-only, also during `-WhatIf`) and enables Plan 2 only when its tier is not
`Standard`: a fresh subscription, or one where `Remove-ArcDemo -DisableDefender`
set the plan to Free. An enabled plan keeps its tier, subPlan and extensions
(for example AgentlessVmScanning) because the template is not applied to it: the
module declares no `extensions`, so ARM what-if would report
`Delete properties.extensions`. A plan other than P2 is preserved, not upgraded;
an unreadable or unknown tier stops Deploy.

## Nested SQL guest

The [nested SQL runbook](nested-sql-demo.md) is the single build/park/wake/remove
path. The proven scratch build is primary; Jumpstart is a manual alternative.
The base Arc/Monitor deployment still does not install SQL.

Define the guest once in the private skin:

```json
"nestedSqlGuest": {
  "enabled": true,
  "parentVmName": "sql-parent",
  "guestVmName": "sql-guest",
  "arcMachineName": "sql-guest"
}
```

These are names in the confirmed demo groups, not credentials or arbitrary
resource IDs. Defaults leave it disabled. Use the same skin for every operation.
The exact configured Windows parent may already be in the retained fleet; a
separately created parent is selected only from that same infra group.

Activate restores outbound networking, starts the parent, starts an Off/Saved
Hyper-V guest without restarting a Running guest, then waits for the guest's
Arc connection. Hibernate uses normal `Stop-VM` (not `-Shutdown`, `-TurnOff` or
forced power-off), waits for Off, then deallocates compute. If guest shutdown
fails, it warns and still attempts spend-reducing parking of all targeted compute;
that is not a guest-data-consistency claim. Remove makes one bounded (ten-minute)
graceful stop of a running guest; if that stop fails it warns and continues,
because the parent, its disks and the guest are deleted with the group anyway. A
parked parent needs no guest boot for removal. Definitions/disks/credentials are
retained on park/wake, not recreated.

Readiness remains read-only. For Active it checks the configured Arc guest's
connection; actual SQL query and extension startup are checked by
`Test-NestedSqlDemoGuest.ps1`. SQL extension startup can lag after a cold wake.
No automatic enrollment, SQL reinstall or credential rotation is a wake step.

## Inventory and retry semantics

### Retained base fleet

Successful subscription deployment outputs are retained as the lifecycle
manifest, filtered by the exact Arc resource group. A later optional-workload-only
deployment can have an empty `vmFleet`; it does **not** delete the earlier Arc
fleet. Lifecycle discovery uses the latest nonempty Arc fleet and retained
native-VM/Container-App IDs. Older AKS manifests are supplemented only by tagged
clusters in the demo infra group. Preserve deployment history while the estate
exists. A manifest whose infra group no longer exists (after `Remove-ArcDemo`) is
stale: `Deploy-ArcDemo.ps1` ignores it, builds a fresh Key Vault and writes a new
manifest. While the infra group exists the vault guard is unchanged: the manifest
vault must be in it, or Deploy refuses. Optional `Remove-ArcDemo.ps1
-PruneDeploymentHistory` deletes this demo's own finished `arc-demo-<timestamp>`
records for the removed Arc group once removal is verified, so a same-prefix rebuild
starts from a clean list (otherwise lifecycle discovery also reads the old
estate's native-VM, Container App and AKS IDs); policy, SRE and other deployment
records are never touched. Missing manifests,
unknown VMs, OS mismatch and IDs outside the demo infra group are errors, not
reasons to guess which VMs to start or delete. For an unused alternative parent,
the private skin can explicitly set `operations.keepParkedVmNames` to an array
of names in this infra group. Each must already be deallocated and outside the
active retained fleet/configured nested parent. Activate never starts or invokes
guests on these VMs; Active readiness verifies they remain deallocated. Other
unknown VMs still fail closed. A listed name must keep existing: once that VM is
deleted, Activate and readiness stop with `Explicit keep-parked VM <name> must
exist … and be deallocated`, so remove deleted VMs from `operations.keepParkedVmNames`
in the same change. Hibernate instead discovers all
VMs, AKS and Container Apps in the explicitly targeted `rg-<prefix>-infra`;
manifest/OS/skin drift is a warning, not a reason to leave that compute running.
No workload ID outside that exact subscription/group is accepted. If the skin
cannot be read, supply the confirmed `-NamePrefix` explicitly; do not guess a
target from a broken skin. Preserve manifests for the stricter later activation.

Actual `storageProfile.osDisk.osType` is checked against the manifest. Azure-native
Windows VMs are never treated as Linux or expected to have an Arc identity.
Monitor-supported hosts, Windows VM Insights hosts, and Arc patch-assessment
targets are distinct sets. Heartbeat compares `_ResourceId`, not computer counts.

Activation restores NAT before starting VMs, starts stopped AKS, and reactivates
the latest Container App revision only if none is active. Already-running/connected
machines are never restarted, but **every activation verifies the hosts**, including
on a retry after partial failure, in one shared wait with a single global deadline
(`-GuestCheckMinutes`, default 12). Each poll costs the same however many hosts
there are: one `az connectedmachine list`, **one** Log Analytics query returning
`max(TimeGenerated)` per `_ResourceId` from `Heartbeat`, and one parallel,
time-boxed ARM read of extension provisioning states. A host passes when its VM is
running, its Arc identity is `Connected` and, for a monitored host, a Heartbeat was
generated **after the VM start time**: the moment activation requested the start, or
the start of the attempt for a host that was already running or starting. A host
with no Heartbeat at the deadline is `pending` for that host only. A VM that is no
longer running, an Arc identity that never connects, or no Heartbeat together with
a `Failed` AMA extension fails. Expected wake is about 12-15 minutes (VM start 3-4,
NAT 1-2, Windows Heartbeat up to about 9) rather than 30-45+.

**No Run Command is used for host checks by default.** Run Command queues behind VM
extension updates (Defender MDE, AMA, Change Tracking), so N blocked Linux VMs used
to cost up to N x 15 minutes and then fail activation although Heartbeats were
fresh. Extension provisioning state (AMA, Change Tracking, MDE) is only a
time-boxed **soft warning**, printed as
`extension <name> Updating for at least <n> min (not a gate)`, recorded in the
per-host evidence and shown by readiness as
non-required `extension/*` rows. The required `heartbeat/*` rows stay the authority.
`-GuestChecks WhenStalled` runs the guest health script only on a host with no
Heartbeat after `-StallMinutes` (default 9), and only when its VM agent is Ready and
no VM extension operation is in flight (it would queue behind it).
`-GuestChecks Always` runs it on every host. Both are asynchronous jobs that share the global
deadline, and neither restarts anything unless `-RepairStalledAgents` is also
supplied. The script checks the Windows Arc `himds` service and, for monitored hosts,
the `MonAgentCore` process with a ten-minute startup wait; it does not assume the
Windows client/MSI `AzureMonitorAgent` service exists or restart the extension
host. Linux checks each required service individually. A guest check that is still
queued at the deadline leaves the host pending, not failed; missing/stopped
required services and command failures still fail.
See [Windows Arc AMA troubleshooting](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-troubleshoot-windows-arc).

The nested SQL guest start keeps its Run Command, but it is submitted as soon as the
parent VM is running, runs concurrently with the host checks and has its own
five-minute budget. If it does not finish in time, the wait relies on the guest's
Arc connection (a warning is recorded). A failed start command, or a guest Arc
machine that is not `Connected` at the deadline, fails activation.

Unless skipped, activation submits assessments only for Arc hosts started/waking
on the attempt. Already-active retries still verify guests but **do not resubmit**
assessments. Use `-AssessPatches` to explicitly request all-host assessment work,
including retrying a failed assessment phase after compute is already running.
It conflicts with `-SkipPatchAssessment`; native VMs are not Arc assessment
targets. The activation result records `not-required` when no hosts need default
submission. This is not proof of earlier assessment success or freshness.
Submission is **not** assessment completion. `-SkipPatchAssessment` opts out;
if Azure returns `OperationConflict` because an assess/patch operation is already
running, activation warns and records `already-in-progress` in its per-host
assessment output. It does not retry, cancel or claim completion. Other errors,
including denied or missing resources, still fail activation.
`-SkipValidate` opts out of final readiness and must never be reported as a
validated demo. Activation never changes workload fault flags.

Use `-ResultPath <PRIVATE_EXISTING_DIRECTORY>\activation-attempt.json` to retain
schema-versioned per-host `guestChecks` (`method`, `startedAtUtc`, `lastHeartbeatUtc`,
`arcStatus`, `extensionStates`, warnings and any restarted service names), the nested
guest outcome, assessment submission states, final readiness and failure information
outside git. Use a new
file per attempt. This report does not include arbitrary guest output or scripts.
After the host wait, a single full readiness snapshot is taken.
If only required `heartbeat/*` checks are pending, activation exits 0 but records
`status:pending`, `readiness:pending` and exact readiness rows, with a re-check
message; a host left pending by the wait also records `status:pending` even with
`-SkipValidate`. Any other required pending/failed check remains a failed activation.
The AI must poll the read-only readiness command to pass before continuing the
presentation, dependent SRE readiness or the conversational incident offer;
activation exit 0 alone does not prove telemetry has arrived.
Completion must come from stdout with no failed/Error-level result; a marker in
stderr alone is not success. `-WhatIf` neither invokes guests nor writes this report.

Fresh deployment creates NAT/PIP before backing compute/extension provisioning;
it does not rely on implicit default outbound. Redeployment preserves an existing
gateway. Hibernation still removes the same named resources; activation recreates
them. See the [documented NAT/subnet resource model](https://learn.microsoft.com/azure/nat-gateway/manage-nat-gateway#create-a-nat-gateway-and-associate-it-with-an-existing-subnet).

Hibernation requires every discovered demo infra-RG VM to be **deallocated**, not merely stopped
or missing from a running-count query. AKS must report `Stopped` and provisioning
`Succeeded` before NAT removal. All active Container App revisions are deactivated;
setting minimum replicas to zero alone does not prevent HTTP scale-out.
Fault flags, storage, DCRAs and guest configuration are preserved.
Retries inspect current state and do not repeat completed state transitions.
In-flight VM deallocation/start and AKS stop/start are waited for, not resubmitted.
Activation waits for AKS Running even with `-SkipValidate`. Individual compute failures warn and do not prevent attempts on other VMs,
clusters, apps or revisions. Final compute verification remains mandatory.
Failures leave completed
parking steps intact: do not wake/redeploy to undo a partial stop. Retry the same
target to finish remaining known transitions (for example a failed PIP deletion).
Network sharing is inspected again before removal after compute has stopped.

Hibernated **required** acceptance is VM deallocation, deployed AKS
Stopped/Succeeded and no active Container App revision. Named NAT/PIP absence
is reported as **non-required cost diagnostics**: unsafe binding conflicts or
cleanup failures warn without undoing or failing verified compute parking.
Inspect these rows before claiming network savings; a foreign NAT is never
detached. Retained groups/Arc records/Monitor configuration and telemetry are
not queried by Hibernated readiness. Use Active readiness before the next demo.
Readiness does not repeat strict manifest or skin validation while parked.
Unknown power or denied/malformed required reads still return nonzero, not
verified Hibernated. This is a deliberate exception to the literal "nonzero only
if still running" request: an unreadable state cannot prove stopped compute.
Actual network inspection/auth errors also remain visible errors, never absence.

No automatic alert/polling pause is introduced: owned alert definitions remain
enabled as before and may incur evaluation/notification costs. Safe restoration
would require preserving exact previous enabled state and reconciling concurrent
changes/companion routing; a generic disable/enable would be unsafe. Evaluate a
separate explicit pause only if measured savings justify that added state.

Before parking, preserve the confirmed target, exact skin/fleet files and their
hashes, prefix/region, deployment-manifest identities and optional revision/fault
state in a private operator handoff outside git. Hibernation needs no VM password
or onboarding secret and does not rotate either. Keep the existing Key Vault and
tenant onboarding identity for later approved deployment/reconciliation.

If the optional SRE layer is attached, finish its approved fault window and
hibernate that layer first under its own procedure. Then preview and run Arc
hibernation. Wake Arc/Monitor and verify Ready before resuming the dependent SRE
layer. Readiness requires no active Container App revisions while parked; its
fault flag remains unchanged. An intentionally retained fault will return on
reactivation, so inspect it rather than silently resetting it.

AKS has additional timing/capacity constraints: allow 15-30 minutes between stop
and start, and do not interleave operations. Stopped state is retained for up to
12 months; standalone pods are not preserved. Storage and other resources remain
billable. See [AKS stop/start](https://learn.microsoft.com/azure/aks/start-stop-cluster)
and [Container App revision management](https://learn.microsoft.com/azure/container-apps/revisions-manage).

Removal waits for both resource groups **and** named subscription policies/budget
to disappear; a rerun skips already-absent objects. Optional `-ForceDeleteWorkspace`
first permanently deletes `law-<prefix>` (irreversible, under its own confirmation):
without it the workspace is only soft-deleted for 14 days and re-creating the same
name recovers its old data. `Removed` read-only verification
needs no deployment history, VM inventory or directory lookup. Its mandatory
boundary is those Azure-owned objects, not tenant-wide cleanup. Subscription-wide Defender
pricing is **preserved by default**; only `-DisableDefender` changes it, and this
can affect other workloads. `-KeepDefender` remains a compatibility switch.
`-RemoveOnboardingIdentity` is separately opt-in and refuses ambiguous identities
or identities with assignments outside the Arc group. Soft-deleted Key Vaults and
retained tenant applications are explicit exceptions, not verified absence.
Default removal deliberately retains the tenant onboarding identity; opt-in SP
deletion does not claim application-object deletion. No purge is performed.
Review these exclusions/delayed billing separately; do not promise a zero bill.

## Credentials and partial deployments

Routine redeployment never resets the onboarding SP credential. Existing VMs
reuse `vm-admin-password` from their existing Key Vault; if that secret was never
stored or the vault cannot be read from the workstation, supply the **current**
password as `-AdminPassword` (SecureString) or as the file an earlier run saved
with `-AdminPasswordPath` (below). Do not supply a new password as a convenience:
credential rotation is a separate approved operation. Fresh deployments generate
the password, save it to Key Vault through Azure Resource Manager and, when
`-AdminPasswordPath` is given, to that file first.
For `Deploy-ArcDemo.ps1`, new Arc onboarding runs through
`Initialize-DemoOnboardingIdentity` once the Arc resource group exists. An
existing `sp-<prefix>-onboard` keeps its credentials: they are never read,
reset or changed. Deploy re-grants its `Azure Connected Machine Onboarding` role
at the Arc group (a deleted group takes the old assignment with it), adds a
one-day credential through Graph, uses it only for onboarding and removes it in
`finally`, then checks the original key IDs are unchanged. Without an SP, it is
created with that role as before and its secret is used for that run only.
`-OnboardingSecret` (SecureString) is an optional override for an operator who
cannot manage the application's credentials; it skips the one-day credential.
Never commit or log either secret.

Deploy selects a retained vault using the saved `keyVaultName` deployment output
and preserves its public-network-access mode. After a fresh build that stopped part
way (no Succeeded manifest yet) it adopts only the vault named by its own Failed or
Canceled `arc-demo-<timestamp>` deployment, never another one, and it refuses to start
while one of its own deployments is still Running. A private-only vault requires the
current password (`-AdminPassword` or the `-AdminPasswordPath` file); Deploy does
not open it for workstation secret reads. A tenant policy can make every new vault
private-only seconds after creation (see
[troubleshooting](troubleshooting.md#the-key-vault-is-private-only-and-az-keyvault-secret-is-refused-forbiddenbyconnection)),
which is why the first save goes through Azure Resource Manager and why the file exists.
**`-AdminPasswordPath`**: the file lives outside the git worktree, in an existing
folder (the build wrapper passes `vm-admin-credential.clixml` in its
[private folder](private-config.md)). A fresh build writes it before any Azure write;
on Windows it is a DPAPI-protected export that only the same user on the same PC can read
(elsewhere PowerShell does not encrypt it). A later run uses it only when
`-AdminPassword` is absent and the vault is not readable or holds no secret; a readable vault
wins, and a fresh build replaces a stale file. It is never printed or logged.
This protects the existing estate, not a nested-build prerequisite. The
[nested build](nested-sql-demo.md) needs no vault and, like Deploy, no supplied
onboarding secret: it uses the same one-day credential flow.

Mandatory compute/Arc waits throw on timeout; inspection errors terminate. Native CLI
failures terminate; authentication/authorization errors are never interpreted as
resource absence. The one retried write is the first Key Vault save of the generated
password: it goes through Azure Resource Manager (no data-plane role has to propagate) and
retries only throttling, 5xx and connection errors, with a bounded backoff; any other
error stops at once.
Extension jobs must complete successfully; guest commands need
an exact completion marker as well as a nonfailed provisioning result. Only the
activation AMA wait permits the explicit `ARC_DEMO_PENDING` stdout marker;
other guest operations cannot use it to bypass completion. Temporary
credential-bearing files and jobs are removed even after failure. Deploy submits the
Bicep deployment with `--no-wait` and polls it, so the parameters file (which holds the
admin password in plain text in the user's temp folder) is deleted as soon as Azure accepts
the request, seconds after it is written, not after the whole build.

Routine deployment preserves an existing Container App's `SIMULATE_CRASH` value
and does not re-bootstrap the sample workload on an existing AKS cluster.
Repairing/replacing that sample is an explicit scenario operation, not an
incidental infrastructure rerun. A retained intentional fault can therefore make
Ready checks pending; disclose it instead of silently resetting it.

## Read-only readiness JSON v1

```powershell
.\scripts\Test-ArcDemoReadiness.ps1 @target `
  -DesiredState Ready -OutputFormat Json -TimeoutSeconds 600
$LASTEXITCODE
```

`-DesiredState` is `Active`, `Ready` (compatible alias/default), `Hibernated` or
`Removed`; `-OutputFormat` is `Json` or `Table`. The supplied state name is echoed.
Default timeout is zero (one snapshot); 0-1800 seconds bounds eventual-consistency
retries (Deploy's final check waits up to 1200 for Windows Heartbeats). Individual CLI reads and service response times still contribute to total
wall time. A hard failure stops retries. There is no fault induction or repair.

One JSON object is written to stdout:

```json
{
  "schemaVersion": 1,
  "workload": "arc-demo",
  "checkedAtUtc": "<UTC ISO-8601>",
  "subscriptionId": "<runtime value>",
  "tenantId": "<runtime value>",
  "resourceGroups": ["rg-<prefix>", "rg-<prefix>-infra"],
  "desiredState": "Ready",
  "status": "pass",
  "checks": [{
    "id": "<stable check identifier>",
    "resourceId": "<exact ARM ID>",
    "required": true,
    "expected": "<expected state>",
    "observed": "<observed state>",
    "status": "pass",
    "message": ""
  }]
}
```

Check statuses: `pass`, `fail`, `pending`, `skipped`. Exit codes: **0** all required
checks pass; **1** required failure or inspection/configuration error; **2** required
eventual-consistency checks still pending at the deadline. Consumers correlate
`resourceId`, not display names or counts. Preserve raw JSON as dated evidence,
outside committed source because it contains live environment identifiers.

Checks cover retained groups, core resources/workbook presence, exact VM power,
Arc connection, recent Heartbeat by expected ARM ID, supported extension
provisioning (soft, non-required `extension/*` diagnostics), DCRA identities, NAT
attachment/presence, AKS power/provisioning and
active Container App revision health. `RunningAtMinScale`/`RunningAtMaxScale` are
valid healthy revision states. Hibernated checks only compute state and named
NAT/PIP cost diagnostics, without inspecting retained monitoring.
Removed checks group/policy/budget absence and emits non-required skipped rows
for retained tenant/shared/soft-delete exceptions. SchemaVersion 1 and existing
0/1/2 exit meanings are unchanged: consumers must honor each row's `required`
flag, not fail merely because any diagnostic row is red.
Extension rows are `required:false`: ARM provisioning state `Updating` can persist
for an hour or more behind an outstanding Defender MDE operation while Heartbeats
are fresh, so a row can read `pending` or `fail` without changing the overall status,
and the command prints one warning. The message carries the state, how long the
host's Arc identity has been connected (the ARM extension model has no timestamp)
and, after 30 minutes, a pointer to [troubleshooting](troubleshooting.md#linux-arm-updating-while-monitoring-guest-handlers-are-healthy).
A `Failed` AMA extension with no recent Heartbeat makes the **required**
`heartbeat/*` row `fail` rather than pending: a failed agent is not telemetry lag.
This is **infrastructure/monitor readiness**, not proof of every guest workload,
Kubernetes pod, policy compliance result, CT inventory cycle, or completed patch
assessment or Defender sensor/AV/EDR health. Demonstrate those separately; never
manufacture fault data to pass.

## Linux monitoring and support stance

In this Azure-VM-backed `MSFT_ARC_TEST` lab, AMA and Linux Change Tracking use the
**Azure VM extension path**, while DCRAs remain on the **Arc machine ID**. Windows
uses Arc extensions. Both VM and Arc CT paths are documented, but ordinary Arc
support is not evidence that this lab's failing guest-extension stack works.
Read-only inspection found stuck Linux Arc extensions and missing CT; the approved
VM-path CT reconciliation produced guest provisioning success and CT records for
all three Linux hosts without restarts. Do not delete stuck Arc extensions or
change paths incidentally. See the [CT support matrix and CLI examples](https://learn.microsoft.com/azure/azure-change-tracking-inventory/change-tracking-inventory-support-matrix).

Linux VM Insights/Dependency Agent map remains disabled. Linux onboarding gives the
Arc agent daemons (`himdsd`, `extd`, `gcad`) a persistent `MSFT_ARC_TEST=true`
systemd drop-in so the extension manager does not restart-loop after a wake; hosts
onboarded by an older Deploy do not have it (limits and one-off fix in
[troubleshooting](troubleshooting.md#linux-arc-extensions-and-assessments-stay-creating-after-every-wake)).
Linux memory and disk
telemetry comes from the four Linux AMA counters in the core DCR (table `Perf`),
not from VM Insights; see the [workbook reference](operational-workbooks.md#linux-memory-and-disk-counters).
The optional
[real SQL workload](sql-engine-workload.md) is separate from Arc SQL: no SQL Server
enabled by Azure Arc/BPA validation is claimed. Hibernate/Activate retain its
engine/database and startup configuration without an implicit install/reset.
Verify real SQL queries separately after wake; Arc readiness does not establish
optional database/worker health. A stopped/disabled worker remains disabled.

### Linux Defender is a separate diagnostic surface

Approved guest diagnostics on the three Linux hosts found installed sensors
reporting `healthy=true`, `licensed=true`, no direct health issues and an active
service, but `passive_mode_enabled=true`, `real_time_protection_enabled=false`
and `engine_load_status="Engine not loaded"`. MDE extension models converged to
Succeeded/onboarding Success after approved startup without a manual MDE repair.
Two extension payloads still recorded event-provider issues that differed from
the newer direct sensor health. Do not label this active-antivirus or complete
EDR/event-delivery validation, or change policy to make the story greener.

The earlier timeout's underlying cause is not established. Keep timestamped ARM,
guest health and existing log evidence separate. No reinstall/retry/removal,
service restart, VM restart or AV-mode change follows from diagnosis alone.

## Validation boundaries

Mocked Pester tests, script parsing, PSScriptAnalyzer, Bicep compile and live
read-only readiness are separate evidence. Keep historical operational evidence
privately and the working-path timings in the [nested SQL runbook](nested-sql-demo.md),
not as extra review gates. They do not prove current health or validate new code.
Keep script completion, independent readiness, fresh telemetry and assessment
completion separate; preserve per-host attempt results outside git.

A fresh deployment, double-deploy idempotency, AKS park/start and delete/recreate
remain separate validation exercises. Operational hibernation only proves the
parked state actually observed, not future activation or fresh deployment.
Run full/destructive smoke cycles only in an explicitly approved disposable lab,
never incidentally against an in-use demo.

An earlier retained-estate wake on 2 November 2026 used the old Run Command host
checks; all eight passed, but independent readiness still reported six Linux
extension models `Updating`. See the [earlier dated evidence](nested-sql-demo.md).
The shared Heartbeat wait replaced those host checks afterwards.

### Default shared-wait park/wake proof: 2 November 2026

An explicitly approved cycle used a clean checkout of merged main `3a70e96`,
including the shared-wait, best-effort parking and nested-parent lifecycle changes.
Default Hibernate ran from 03:00:50 to 03:09:25 UTC: **8 minutes 35.2 seconds**.
Direct post-park reads verified the eight fleet VMs (plus a since-deleted prototype VM) deallocated, the named NAT
gateway and public IP absent, and all 35 retained Container App revisions inactive
and `Stopped`. For independent revision reads, use
`az containerapp revision list --all`: the default list hides inactive revisions.

Default Activate ran from 03:13:25 to 03:28:19 UTC: **14 minutes 54.1 seconds**
wall-clock, exit 0 and result `pass`. No skip flags, host-check Run Commands, explicit
service restarts or repair fallback were used. The shared 12-minute host deadline
is not an end-to-end wake-time promise: preflight, network restoration, compute
starts and final readiness also contribute to wall-clock time.

All eight monitored hosts passed using `arm+heartbeat`; the saved results recorded
Arc `Connected`, empty `restartedServices` and these post-start Heartbeats.
Times below are UTC on 2 November, not a current-health snapshot.

| Host | Method | lastHeartbeatUtc |
| --- | --- | --- |
| win-sql-01 | arm+heartbeat | 03:22:31.5745042 |
| win-sql-02 | arm+heartbeat | 03:23:13.0873741 |
| win-app-01 | arm+heartbeat | 03:22:48.6951573 |
| win-app-02 | arm+heartbeat | 03:22:51.0222153 |
| win-app-03 | arm+heartbeat | 03:22:54.3905789 |
| lnx-app-01 | arm+heartbeat | 03:18:38.4845995 |
| lnx-app-02 | arm+heartbeat | 03:17:04.7261035 |
| lnx-app-03 | arm+heartbeat | 03:18:47.4256979 |

The nested guest's separate parent Run Command ran concurrently from
03:16:57.544 to 03:18:09.964 UTC, about **72.42 seconds**, within its five-minute
budget. Its start result and Arc connection passed. Five Windows patch assessments
were submitted; the three Linux submissions reported `already-in-progress`
conflicts, without retry or cancellation. Submission is not completion.

Independent read-only Active readiness passed at 03:38:50 UTC with no required
non-pass rows. Six Linux AMA/Change Tracking VM-extension models still reported
`Updating` as non-required warnings. The activation REST snapshots had reported
`Succeeded` for the same extension paths; the cause of the differing readbacks
was not established. This is not proof of extension completion. Required
Heartbeats passed, and no extension or sensor repair was attempted.

This proves one short retained-estate park/wake, including fresh post-start
Heartbeats without the old explicit service restarts. Arc records still read
`Connected` before wake while their backing VMs were parked, so an observed
`Disconnected` to `Connected` transition, long-park reconnection and guest service
health were not proven. Fresh deployment, double-deploy idempotency, AKS,
assessment completion, full removal and rebuild remain outside this proof;
drift, denial and partial-failure paths remain mocked. The estate was left awake.

The best-effort parking and shared-wait changes have local coverage for
missing manifests, unlisted VMs, OS/skin drift, foreign NAT, partial deallocation,
denied/unknown power, one global deadline with per-host pending/fail outcomes, soft
extension warnings, opt-in Run Command and its script's five-minute AMA start and
ten-minute pending evidence, and
telemetry-only pending versus real service/readiness failures. Native-process
stderr and explicit-null JSON regressions remain. Mocks cannot prove Azure
allocation, guest boot timing, RunCommand delivery/truncation, eventual ARM
consistency or ingestion latency. Approve a disposable smoke cycle separately;
see [cost.md](cost.md#proposed-disposable-smoke-cycle-not-executed).
