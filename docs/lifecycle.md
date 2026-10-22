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
.\scripts\Test-Prerequisites.ps1 -SubscriptionId <SUB> -TenantId <TENANT>
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
requires Microsoft.App; AKS additionally needs ContainerService, ManagedIdentity,
Resources, Storage and ContainerInstance for its deployment script. AzureArcData
is only needed for the experimental SQL path.

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

## Inventory and retry semantics

Successful subscription deployment outputs are retained as the lifecycle
manifest, filtered by the exact Arc resource group. A later optional-workload-only
deployment can have an empty `vmFleet`; it does **not** delete the earlier Arc
fleet. Lifecycle discovery uses the latest nonempty Arc fleet and retained
native-VM/Container-App IDs. Older AKS manifests are supplemented only by tagged
clusters in the demo infra group. Preserve deployment history. Missing manifests,
unknown VMs, OS mismatch and IDs outside the demo infra group are errors, not
reasons to guess which VMs to start or delete. Hibernate instead discovers all
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
the latest Container App revision only if none is active. It restarts guest
agents only for newly started/disconnected machines. Already-running/connected
machines are not restarted, but **every activation verifies guest health**, including
on a retry after partial failure. Windows Arc checks the `himds` service and,
for monitored hosts, the `MonAgentCore` process with a ten-minute startup wait.
Host commands are submitted concurrently through the existing checked jobs.
Progress identifies the jobs still awaited. A healthy Arc service with AMA not
yet visible at the deadline records guest `pending` and warns; missing/stopped
required services, command/transport failures and denied reads still fail.
It does not assume the Windows client/MSI `AzureMonitorAgent` service exists or
restart the extension host. Linux checks each required service individually.
See [Windows Arc AMA troubleshooting](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-troubleshoot-windows-arc).

Unless skipped, activation submits assessments only for Arc hosts started/waking
on the attempt. Already-active retries still verify guests but **do not resubmit**
assessments. Use `-AssessPatches` to explicitly request all-host assessment work,
including retrying a failed assessment phase after compute is already running.
It conflicts with `-SkipPatchAssessment`; native VMs are not Arc assessment
targets. The activation result records `not-required` when no hosts need default
submission. This is not proof of earlier assessment success or freshness.
Submission is **not** assessment completion. `-SkipPatchAssessment` opts out;
`-SkipValidate` opts out of final readiness and must never be reported as a
validated demo. Activation never changes workload fault flags.

Use `-ResultPath <PRIVATE_EXISTING_DIRECTORY>\activation-attempt.json` to retain
schema-versioned per-host guest checks, restarted service names, assessment
submission states, final readiness and failure information outside git. Use a new
file per attempt. This report does not include arbitrary guest output or scripts.
After compute and Arc checks, a single full readiness snapshot is taken.
If only required `heartbeat/*` checks are pending, activation exits 0 but records
`status:pending`, `readiness:pending` and exact readiness rows, with a re-check
message. Any other required pending/failed check remains a failed activation.
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
to disappear; a rerun skips already-absent objects. `Removed` read-only verification
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
stored, supply the **current** password as `-AdminPassword` (SecureString).
Do not supply a new password as a convenience: credential rotation is a separate
approved operation. Fresh deployments save the generated password to Key Vault.
If new Arc onboarding is required and the SP already exists, supply its existing
secret as `-OnboardingSecret` (SecureString). Never commit or log either secret.

Mandatory compute/Arc waits throw on timeout; inspection errors terminate. Native CLI
failures terminate; authentication/authorization errors are never interpreted as
resource absence. Extension jobs must complete successfully; guest commands need
an exact completion marker as well as a nonfailed provisioning result. Only the
activation AMA wait permits the explicit `ARC_DEMO_PENDING` stdout marker;
other guest operations cannot use it to bypass completion. Temporary
credential-bearing files and jobs are removed even after failure.

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
Default timeout is zero (one snapshot); 0-600 seconds bounds eventual-consistency
retries. Individual CLI reads and service response times still contribute to total
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
Arc connection, supported extension provisioning, DCRA identities, recent
Heartbeat by expected ARM ID, NAT attachment/presence, AKS power/provisioning and
active Container App revision health. `RunningAtMinScale`/`RunningAtMaxScale` are
valid healthy revision states. Hibernated checks only compute state and named
NAT/PIP cost diagnostics, without inspecting retained monitoring.
Removed checks group/policy/budget absence and emits non-required skipped rows
for retained tenant/shared/soft-delete exceptions. SchemaVersion 1 and existing
0/1/2 exit meanings are unchanged: consumers must honor each row's `required`
flag, not fail merely because any diagnostic row is red.
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

Linux VM Insights/Dependency Agent map remains disabled. SQL-shaped workload
simulation is separate from Arc SQL: no SQL Server enabled by Azure Arc/BPA
validation is claimed in this Azure-only lab.

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
read-only readiness are separate evidence. Keep dated operational observations in
[the engineering reference](module-map.md#dated-operational-evidence-not-presenter-material),
not agent instructions. They do not prove current health or validate new code.
Keep script completion, independent readiness, fresh telemetry and assessment
completion separate; preserve per-host attempt results outside git.

A fresh deployment, double-deploy idempotency, AKS park/start and delete/recreate
remain separate validation exercises. Operational hibernation only proves the
parked state actually observed, not future activation or fresh deployment.
Run full/destructive smoke cycles only in an explicitly approved disposable lab,
never incidentally against an in-use demo.

The simplified predicates, retry handling and Removed inspection are covered by
local mocked regression checks, not a newly authorized live park/wake/teardown
exercise. Prior operational evidence does not validate these source changes.

The best-effort parking and concurrent cold-start changes have local coverage for
missing manifests, unlisted VMs, OS/skin drift, foreign NAT, partial deallocation,
denied/unknown power, a five-minute AMA start, ten-minute pending evidence and
telemetry-only pending versus real service/readiness failures. Native-process
stderr and explicit-null JSON regressions remain. Mocks cannot prove Azure
allocation, guest boot timing, RunCommand delivery/truncation, eventual ARM
consistency or ingestion latency. Approve a disposable smoke cycle separately;
see [cost.md](cost.md#proposed-disposable-smoke-cycle-not-executed).
