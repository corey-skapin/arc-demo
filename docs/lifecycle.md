# Demo lifecycle and readiness contract

This is a deliberately un-hardened, single-region demo, not a production
reference. The maintained entry points are the PowerShell scripts. Always pass
the **confirmed** subscription and tenant at runtime; neither belongs in a skin.
Use the same skin/prefix throughout. CLI defaults are not changed by the scripts.

## Supported operations

```powershell
$target = @{ SubscriptionId = '<SUB>'; TenantId = '<TENANT>'; SkinPath = '.\config\demo-skin.json' }
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
```

Preflight is **read-only**: tooling, explicit context, effective inherited/group
Owner (or Contributor + User Access Administrator), and needed provider
registrations. Supplying a deployer principal ID does not bypass RBAC checks.
Missing registrations must be approved and registered separately. Baseline
providers include KeyVault, DevTestLab and Consumption. Optional Container Apps
requires Microsoft.App; AKS additionally needs ContainerService, ManagedIdentity,
Resources, Storage and ContainerInstance for its deployment script. AzureArcData
is only needed for the experimental SQL path.

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
reasons to guess from names.

Actual `storageProfile.osDisk.osType` is checked against the manifest. Azure-native
Windows VMs are never treated as Linux or expected to have an Arc identity.
Monitor-supported hosts, Windows VM Insights hosts, and Arc patch-assessment
targets are distinct sets. Heartbeat compares `_ResourceId`, not computer counts.

Activation restores NAT before starting VMs, starts stopped AKS, and reactivates
the latest Container App revision only if none is active. It restarts guest
agents only for newly started/disconnected machines. Already-running/connected
machines are not restarted, but **every activation verifies guest health**, including
on a retry after partial failure. Windows Arc checks the `himds` service and,
for monitored hosts, the `MonAgentCore` process with a bounded startup wait.
It does not assume the Windows client/MSI `AzureMonitorAgent` service exists or
restart the extension host. Linux checks each required service individually.
See [Windows Arc AMA troubleshooting](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-troubleshoot-windows-arc).

Unless skipped explicitly, **each activation submits assessments for all retained
Arc hosts**, even when they were already running/connected. This completes the
normal assessment phase on a retry; native Azure VMs are not Arc assessment
targets. Submission is **not** assessment completion. `-SkipPatchAssessment` opts out;
`-SkipValidate` opts out of final readiness and must never be reported as a
validated demo. Activation never changes workload fault flags.

Use `-ResultPath <PRIVATE_EXISTING_DIRECTORY>\activation-attempt.json` to retain
schema-versioned per-host guest checks, restarted service names, assessment
submission states, final readiness and failure information outside git. Use a new
file per attempt. This report does not include arbitrary guest output or scripts.
Completion must come from stdout with no failed/Error-level result; a marker in
stderr alone is not success. `-WhatIf` neither invokes guests nor writes this report.

Fresh deployment creates NAT/PIP before backing compute/extension provisioning;
it does not rely on implicit default outbound. Redeployment preserves an existing
gateway. Hibernation still removes the same named resources; activation recreates
them. See the [documented NAT/subnet resource model](https://learn.microsoft.com/azure/nat-gateway/manage-nat-gateway#create-a-nat-gateway-and-associate-it-with-an-existing-subnet).

Hibernation requires every expected VM to be **deallocated**, not merely stopped
or missing from a running-count query. AKS must report `Stopped` and provisioning
`Succeeded` before NAT removal. All active Container App revisions are deactivated;
setting minimum replicas to zero alone does not prevent HTTP scale-out.
Fault flags, storage, DCRAs and guest configuration are preserved.
Retries inspect current state and do not repeat completed state transitions.

Before parking, preserve the confirmed target, exact skin/fleet files and their
hashes, prefix/region, deployment-manifest identities and optional revision/fault
state in a private operator handoff outside git. Hibernation needs no VM password
or onboarding secret and does not rotate either. Keep the existing Key Vault and
tenant onboarding identity for later approved deployment/reconciliation.

If the optional SRE layer is attached, finish/reset its approved fault window and
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

Removal waits for both resource groups to disappear. Subscription-wide Defender
pricing is **preserved by default**; only `-DisableDefender` changes it, and this
can affect other workloads. `-KeepDefender` remains a compatibility switch.
`-RemoveOnboardingIdentity` is separately opt-in and refuses ambiguous identities
or identities with assignments outside the Arc group. Soft-deleted Key Vaults and
retained tenant applications may need operator review. Do not promise a zero bill.

## Credentials and partial deployments

Routine redeployment never resets the onboarding SP credential. Existing VMs
reuse `vm-admin-password` from their existing Key Vault; if that secret was never
stored, supply the **current** password as `-AdminPassword` (SecureString).
Do not supply a new password as a convenience: credential rotation is a separate
approved operation. Fresh deployments save the generated password to Key Vault.
If new Arc onboarding is required and the SP already exists, supply its existing
secret as `-OnboardingSecret` (SecureString). Never commit or log either secret.

Mandatory waits throw on timeout; inspection errors terminate immediately. Native CLI
failures terminate; authentication/authorization errors are never interpreted as
resource absence. Extension jobs must complete successfully; guest commands need
an exact completion marker as well as a nonfailed provisioning result. Temporary
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

`-DesiredState` is `Ready` or `Hibernated`; `-OutputFormat` is `Json` or `Table`.
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
valid healthy revision states. Hibernated hosts intentionally skip Heartbeat.
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
read-only readiness are separate evidence. The approved CT repair verifies only
that repair. An approved active-estate rehearsal on 20 October 2026 verified all
eight exact VM/Arc/Heartbeat identities and all 79 infrastructure/monitor checks.
Raw timestamps/IDs stay in private session evidence; that is a point-in-time
pre-fault snapshot, not an ongoing health guarantee. Windows Heartbeats arrived
after Arc reconnected without an agent repair; keep pending status until fresh
expected-ID telemetry is actually visible.

Targeted VM starts and a passing readiness snapshot do not prove the full
`Activate-ArcDemo.ps1` guest-check/assessment path succeeded. An approved activation
attempt reached Monitor Ready after its Windows guest step failed; the failure
was an incorrect Windows AMA service assumption, not a missing completion-marker
transport fix. Keep the script outcome and runtime snapshot separate, and retain
the corrected attempt's per-host results rather than skipping guest validation.

An approved corrected activation retry on 21 October 2026 completed normally:
all eight guest checks passed without unnecessary service restarts, all eight
Arc assessments were submitted, and independent readiness passed all 79 checks
with fresh expected-ID Heartbeats and the healthy, non-faulted Container App.
That retry reused the already-running estate/network from the earlier partial
attempt; it does not prove a fresh cold-start run of every corrected branch.
Private timestamped results remain outside git.

A fresh deployment, double-deploy idempotency, AKS park/start and delete/recreate
remain separate validation exercises. Operational hibernation only proves the
parked state actually observed, not future activation or fresh deployment.
Run full/destructive smoke cycles only in an explicitly approved disposable lab,
never incidentally against an in-use demo.
