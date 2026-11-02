# Azure Arc demo build and operations runbook

**Operator procedure, not the presentation script.** Presenters start at
[the docs index](README.md), then their generated `.local/presenter-runsheet.md`.
The maintained deployment path is `scripts\Deploy-ArcDemo.ps1` plus Bicep. Do not
replay old ad-hoc portal/CLI builds against a running demo. Start with
[AGENTS.md](../AGENTS.md), [lifecycle safety/contract](lifecycle.md), and the
[presenter template](runsheet.md) only when preparing the local guide.

## Prepare the local presenter guide

Do this after successful approved deployment/activation and independent Active
readiness. The presenter receives `.local/presenter-runsheet.md` and follows it
top to bottom; no input card, customer customization or ID lookup is required.
Deployment/lifecycle behavior is unchanged.

Plain Markdown cannot interpolate an external JSON file. The offline
`scripts\New-PresenterRunsheet.ps1` fills the single tracked `docs\runsheet.md`
template from `.local\demo-context.json`. The entire `.local/` folder is ignored.
Capture the following **nonsecret** fields from the explicit setup inputs and
actual deployment outputs/saved evidence, never CLI defaults or guessed IDs:

| Field | Source |
| --- | --- |
| `schemaVersion` | Numeric `1` |
| `subscriptionId`, `tenantId` | The operator-confirmed runtime target |
| `recordedAtUtc` | UTC timestamp of the context/evidence being saved, not the generation time |
| `resourceGroups` | Object with actual `arc` and `infra` group names |
| `workspaceResourceId`, `workbookResourceId` | Exact workspace and saved Estate Overview workbook IDs |
| `windowsMachineResourceId`, `linuxMachineResourceId` | Exact monitored Arc machine IDs selected for the tour, not backing VM IDs |
| `heartbeatAlertResourceId`, `actionGroupResourceId` | Exact heartbeat rule and action group IDs |
| `lobMachineName` (optional) | The separately prepared LOB host; omit if not part of this demo |
| `sqlMachineResourceId` (optional) | Actual prepared SQL host Arc ID, with adjacent verified `sql-engine-status.json` from [real SQL Status](sql-engine-workload.md); omit until actually prepared |
| `sqlIncidentAlertResourceId` (optional) | Exact prepared SQL log-alert ID; requires the SQL host/proof above. Adds a concrete alert link, not an alert-delivery or investigation claim |
| `capacityWorkbookResourceId`, `optimisationWorkbookResourceId` (optional) | Actual published IDs from the scoped [operational workbook setup](#optional-capacity-and-optimisation-workbooks); never preview or draft IDs. Adds optional links, not current-health or savings proof |
| `companionSreRunsheetPath` (optional) | Absolute path to the companion's actual generated guide; linked only if it exists |

The assistant/operator writes the approved values once, then runs:

```powershell
# $context contains only the fields above, from approved inputs and saved outputs.
New-Item -ItemType Directory -Path .\.local -Force | Out-Null
$context | ConvertTo-Json -Depth 4 | Set-Content .\.local\demo-context.json
.\scripts\New-PresenterRunsheet.ps1
```

No sign-in, Azure read/write, guest command or health check occurs in generation.
Missing/foreign/malformed IDs fail explicitly before replacing the output.
The context timestamp is printed prominently: old evidence is not current health.
The generator does not read a credential store, copy a whole deployment manifest
or retain passwords, recipient emails, tokens or private configuration files.

Refresh the context and regenerate after successful preparation changes the
resources or selected hosts. An activation that leaves telemetry pending is not
a successful presenter handoff; poll readiness under the normal contract first.
The operator owns that check, not the presenter. Use the same convention in the
companion repo; a missing companion guide produces a plain handoff note, not a
broken or guessed relative path.

## Optional capacity and optimisation workbooks

These are optional read-only engineer surfaces after setup, not additional
workload infrastructure or more required minutes in the 20-30 minute tour.
They reuse existing `Perf`/`InsightsMetrics` and Arc inventory; the views make no
guest, SQL, extension, power, price or schedule changes. The one collection change
is the explicitly approved Linux memory and disk counters in the core DCR, which
replaced three placeholder names that were never valid for Linux AMA.
What each section shows, the evidence rules and the thresholds are in the
[workbook reference](operational-workbooks.md). DR and Azure Migrate assessment
are outside this demo.

The scoped entry point defaults to **Preview**, which verifies the explicit
tenant/subscription, reads only the existing workspace/Arc group and the
deterministic workbook target, then returns rendered JSON with `published=false`.
It does not invoke ARM deployment or ARM what-if. It never silently registers a
provider or changes CLI defaults. Failed/denied/unknown reads stop the operation.
Use the same confirmed prefix/skin; an explicitly supplied missing skin fails.

```powershell
$workbookTarget = @{
    SubscriptionId = '<SUB>'; TenantId = '<TENANT>'
    NamePrefix = '<CONFIRMED_PREFIX>'; SkinPath = '<PRIVATE_SKIN_PATH>'
    WorkspaceResourceId = '<EXISTING_LAW_RESOURCE_ID>'
}
.\scripts\Set-OperationalWorkbook.ps1 @workbookTarget -Purpose capacity
.\scripts\Set-OperationalWorkbook.ps1 @workbookTarget -Purpose optimisation
# Only after separate publication approval; this is still a no-write preview.
.\scripts\Set-OperationalWorkbook.ps1 @workbookTarget -Purpose capacity -Action Deploy -WhatIf
# Review copies: a separate "(draft)" resource; the published workbook stays intact.
.\scripts\Set-OperationalWorkbook.ps1 @workbookTarget -Purpose capacity -Draft -Action Deploy
.\scripts\Set-OperationalWorkbook.ps1 @workbookTarget -Purpose optimisation -Draft -Action Deploy
# Promotion after review: the same command without -Draft replaces the published workbook in place.
.\scripts\Set-OperationalWorkbook.ps1 @workbookTarget -Purpose capacity -Action Deploy
.\scripts\Set-OperationalWorkbook.ps1 @workbookTarget -Purpose optimisation -Action Deploy
# Remove only an owned draft (no Arc roster is read).
.\scripts\Set-OperationalWorkbook.ps1 @workbookTarget -Purpose capacity -Draft -Action Remove
```

Actual publication is a separate approved operation, confirmed by ShouldProcess.
`-DisplayUtcOffsetHours` sets the default display time zone of the scheduling heat-map
(the workbook selector can change it).

Only the selected shared workbook is created/updated by the small Bicep module,
with an exact-content readback. Stable IDs are derived from workspace/purpose
(drafts use their own ID, a `lifecycle: draft` tag and a banner);
a foreign existing workbook is never adopted. No whole-lab deployment, IAM or
repair is used. Workbooks survive parking with the workspace, contain no active
jobs and disappear with the Arc group on approved normal removal. Existing
lifecycle/readiness gates are unchanged. Re-publishing changed source or
refreshing roster/topology requires new approval, not an incidental wake.
The roster is bounded to 1-50 exact Arc IDs because every item query embeds it.
Each workbook links to the other (a draft to the draft, a published workbook to the published one), so publish both
for the links to resolve; the portal URL carries the confirmed tenant.

**Coverage before conclusions:** each table starts with every selected Arc ID,
including hosts without samples. One canonical source is selected per host and
metric across the window, source names and observed hours stay visible, missing
values are null (never zero), invalid samples warn, and charts omit absent
intervals instead of drawing zeros. The default window is 14 days because the lab
runs sporadically; coverage is observed one-minute bins, not uptime or an agent SLA.
Evidence is adequate only with the selected observed hours (default 3, an illustrative
setting for an on-demand lab) and 80% sampling while active, so newly collected Linux memory
and disk read as thin for its first few running hours. Low CPU alone never yields a sizing recommendation, and SQL host
telemetry does not establish engine capacity, database performance or licence needs.
Thresholds (CPU 80%, sustained 30 minutes, memory 85%, disk free 15%, low CPU P95
20%) are editable, labelled illustrative triage values, not right-sizing or
availability guarantees; the fixed constants are listed on each workbook's
*Evidence and method* tab.

**Topology and ownership:** the roster contains exact Arc IDs only, never their
Azure backing-VM duplicates. The nested guest is declared once in the private
skin's `nestedSqlGuest` block (parent VM and Arc machine name); the script adds
the pair to the roster as a declared parent and guest. A guest that is not yet an
Arc machine in the group is skipped with a warning and appears after onboarding
and a republish; a disconnected guest is still listed and reads *No telemetry*
until it reports. Any other machine is `unclassified` unless an optional private
`-TopologyPath` JSON declares it: `{"schemaVersion":1,"machines":[...]}`, each
entry with `resourceId`, `layer` (`parent`, `guest` or `standalone`) and, for
guests only, `parentResourceId` referencing another selected, explicitly classified
parent. A conflict between the file and the skin is an error. Declared topology is a
relationship, not physical hardware capacity: no hardware totals are calculated and
parent and guest measurements are never added. A parent's own counters do not reflect
its guest's load, so a quiet parent is insufficient evidence, not headroom. The
optimisation view reads current `owner`/`costcenter`/`role` tags through Resource
Graph for those exact IDs. Empty/missing ARG results are missing inventory evidence,
not proof that a resource or owner is absent; query failures must be reported.

The optional cost scenario is typed into the workbook for one selected non-guest
workload: `baseline x eligible share x hours off / 168`, labelled illustrative and
not billing, a price, a calendar month, realised savings or a safe shutdown schedule.
Fixed, licensed, retained-storage, monitoring and security costs stay outside it.
No price API, inferred currency, estate multiplication, or stop/delete/schedule
action is provided.

After actual publication, save only the returned published workbook IDs as the
optional context fields above and regenerate the existing presenter guide.
Do not add preview or draft IDs or claim portal rendering has been observed from
source validation alone. Documented workbook deployment and scope conventions:
[programmatic workbooks](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-automate)
and [workbook resource templates](https://learn.microsoft.com/azure/templates/microsoft.insights/2023-06-01/workbooks).

Local Pester covers rendering, scoping, roster and topology guards, size bounds,
draft handling and scenario arithmetic. `tests/OperationalWorkbookQueries.Tests.ps1`
is deliberately opt-in: pass explicit workspace/subscription/tenant via
`New-PesterContainer -Data` to execute the production item queries read-only
against deterministic literal tables. It ingests nothing, touches no guests and
covers spikes versus sustained pressure, missing, invalid and thin evidence, parked
gaps, Linux counter names and pseudo mounts, separate parent/guest rows and the
scenario arithmetic. Normal CI skips those Azure-dependent tests; a local mock
pass does not imply KQL execution or a published workbook.

## Build everything in order (optional wrapper)

`scripts\Invoke-ArcDemoBuild.ps1` runs the maintained scripts in one fixed order
(P0-P11) for a from-zero build of the base estate and the optional parts. It adds
no logic of its own: every step is an existing script, so the sections below still
describe what each step does. It is **plan only by default**. `-Execute` runs the
steps not yet recorded as done in the private `build-state.json`, so a stopped
build resumes where it stopped. Keep the config, state and evidence in the
[private build folder](private-config.md).

```powershell
$build = @{ SubscriptionId = '<SUB>'; TenantId = '<TENANT>'; BuildConfigPath = '<PRIVATE>\build.json' }
.\scripts\Invoke-ArcDemoBuild.ps1 @build        # plan: order, status, approvals, blockers, time
.\scripts\Invoke-ArcDemoBuild.ps1 @build -Execute -From P2 -To P4 `
    -ApproveCostStart -AcceptWindowsEvaluationTerms -AcceptSqlDeveloperTerms
```

| Step | What runs | Needs |
| --- | --- | --- |
| P0, P1 | Read-only preflight (tools, access, providers, repo state, soft-deleted workspace name, build window against the VM auto-shutdown) and onboarding-identity check | |
| P2 | `Deploy-ArcDemo.ps1` with the private skin | `-ApproveCostStart` |
| P3 | `Prepare-NestedSqlParent.ps1`: the Hyper-V parent for the nested guest. Runs after Deploy with the lab Active (it refuses a parked lab) and writes the nested build input into the private folder. A reported `status` of `pending` or `fail` is not recorded as done, and it is safe to re-run | `-AcceptWindowsEvaluationTerms`, `-AcceptSqlDeveloperTerms` |
| P4 | `New-NestedSqlDemo.ps1`: takes the build input from P3, adds the parent and guest names, resolves the parent VM ID and onboarding application at run time, uses a one-day onboarding credential. The guest Administrator credential is requested at the start of `-Execute` (pass `-GuestCredential` to run unattended) and is never stored | |
| P5 | Real SQL on the SQL host: `Stage-DemoMedia.ps1` stages the hash-pinned ISO from `config/demo-media.json` (or the config's `mediaManifestPath`), then `ProtectArcSql`, `Install`, `Status` | `-AcceptSqlDeveloperTerms` |
| P6 | `Set-SqlIncidentAlert.ps1` and `Set-OperationalWorkbook.ps1` (capacity, optimisation) | |
| P7 | `Test-ArcDemoReadiness.ps1 -DesiredState Active`, re-checked for up to 20 minutes | |
| P8 | Companion repo: LOB alert rule and LOB app | |
| P9 | Companion repo: `Deploy-SreAgent.ps1` preview, create, then readiness. The agent bills from creation; the create step passes the script's own `-ApproveParentCreation`. Preview and create are skipped when the parent already exists (see below) | `-ApproveSreCreation`; `-ApproveSubscriptionGrant` adds the opt-in alert-access grant |
| P10 | Presenter context and guide for this repo (the SRE guide only if its context exists) | |
| P11 | `Export-ArcDemoInventory.ps1`, then `Test-ArcDemoParity.ps1` | |

- The plan shows each step as `ready`, `done`, `skipped` (with the reason) or
  `blocked`. Blocked means the script is not in the checkout yet, it does not
  accept an argument the wrapper passes, or an input file is missing.
- Nothing starts if any selected step is blocked, an approval switch is missing,
  or the state records P2 as done while the infra group no longer exists (a
  teardown happened; delete the state file to start a new build).
- Read-only steps (P0, P1, P5 `Status`, P7, P9 readiness, P11) run
  again on every `-Execute`. A failed or interrupted P4 or P9 deploy is not retried
  until you have inspected it and pass `-Force`; `-Force` also re-runs steps
  recorded as done. A step that could not even start (for example a lookup failed
  or the credential prompt was cancelled) is recorded as `blocked` and stays retryable.
- `Deploy-SreAgent.ps1` refuses an existing SRE parent, even with `-WhatIf`. So a
  read-only check of `rg-<prefix>-sre` (the agent name comes from the SRE skin)
  runs first: when the parent exists, P9 preview and create are **skipped**, not
  failed, and need no approval; when the check cannot be read, they are `blocked`
  with the exact error. P9 therefore belongs after a confirmed removal; use
  `Initialize-SreConfiguration` for configuration-only changes to a running agent.
- `-From`, `-To` and `-Only` take phase names; `-WhatIf` is the same as the plan;
  pass `-Confirm:$false` for unattended runs. The plan's minutes are typical
  timings (about 3.5 hours end to end), not a promise. Billable resources start
  at P2; reprice with [cost.md](cost.md).
- The wrapper only builds. Teardown stays with `Hibernate-ArcDemo.ps1` and
  `Remove-ArcDemo.ps1` (and the companion's own scripts first); the opt-in
  `-ForceDeleteWorkspace` and `-PruneDeploymentHistory` switches for a same-prefix
  rebuild are described with Remove below and decided at teardown time.

### Snapshot and parity (read-only)

```powershell
$target = @{ SubscriptionId = '<SUB>'; TenantId = '<TENANT>'; SkinPath = '<PRIVATE>\arc-skin.json' }
.\scripts\Export-ArcDemoInventory.ps1 @target -OutputPath <PRIVATE>\evidence\inventory-before.json
.\scripts\Test-ArcDemoParity.ps1 @target -SnapshotPath <PRIVATE>\evidence\inventory-before.json -Feature RealSql, Sre
```

The snapshot records names, types, sizes, power states, associations, alert and
workbook definitions, policy/budget/Defender state, onboarding-credential
metadata and the retained manifest's fleet. It never reads a secret. A denied or
failed read is recorded verbatim in its section and the script exits 1.
Take one before a teardown and one after a rebuild.

The parity check compares a snapshot (or a fresh read) with
[`config/expected-inventory.json`](../config/expected-inventory.json) and the
manifest's fleet, exiting 0 only when every check passes. Run it while the estate
is Active (parked estates have no NAT gateway). Update the expected list in the
same change that adds or removes a named object.

## 1. Choose the target and skin

Use a demo subscription where the operator has effective subscription Owner or
Contributor plus User Access Administrator, and permission to create an Arc
onboarding identity if needed, or to add and remove a credential on the existing
one (application owner or administrator). PowerShell 7.4+, Azure CLI 2.60+ and
Bicep are required. No Az PowerShell module, production framework or SRE Agent
is required.

```powershell
az login --tenant <TENANT>
az account show --subscription <SUB> --query "{id:id,tenantId:tenantId,user:user.name}" -o table
$target = @{ SubscriptionId = '<SUB>'; TenantId = '<TENANT>'; SkinPath = '<PRIVATE_SKIN_PATH>' }
```

Confirm those values; do not rely on default CLI context. Copy a bundled skin
outside git for a new lab; edit that private copy's email, labels, prefix and
workload toggles. Preserve an existing lab's retained inputs instead.
IDs and secrets stay out of source.
`config\dummy-customer.demo-skin.json` illustrates portability. An explicit missing
skin, malformed boolean, invalid prefix or fleet is an error, never a fallback.
Relative fleet paths resolve against the repo root.

## 2. Read-only preflight and preview

```powershell
.\scripts\Test-Prerequisites.ps1 -SubscriptionId <SUB> -TenantId <TENANT>
.\scripts\Deploy-ArcDemo.ps1 @target -AdminEmail <EMAIL> -WhatIf
```

Preflight does not register providers, install CLI extensions or change context.
It reports every unregistered provider and every missing CLI extension (`connectedmachine`,
plus `containerapp` for Container Apps) in one error with the exact fix, for example
`az extension add --name connectedmachine --yes`; resolve missing providers with
separate operator authorization, using the exact providers reported
by deployment preflight for the selected workloads. Supplying
`-DeployerPrincipalId <OBJECT_ID>` bypasses only Graph user discovery, not RBAC.
SKU restriction and regional/family vCPU quota checks do not guarantee capacity. If Azure still
refuses allocation, Deploy prints the options and never switches VM size or
region on its own; re-running the same command resumes.
Review [cost assumptions](cost.md) before agreeing to a budget.

## 3. Deploy (approved creation/reconciliation)

```powershell
.\scripts\Deploy-ArcDemo.ps1 @target -AdminEmail <EMAIL>
```

Default: 5 Windows Server hosts across 2016/2019/2022 and 3 Ubuntu 22.04 hosts,
Arc-enabled with `MSFT_ARC_TEST=true` for this demo-only simulation. SQL-capable
hosts do not imply SQL Server is installed. Optional flags are independent:
`-DeployAzureVMs $true`, `-DeployContainerApps $true`, `-DeployAks $true`.
For custom tiers, use `-OnPremFleetPath <fleet.json>`; see
[legacy fleet support](legacy-os-fleet.md). Represented legacy hosts are not
reported as deployed.

Real SQL setup is a separate approved operation using
[the isolated Developer workload helper](sql-engine-workload.md).
Deployment has no SQL installation switch; use the separate SQL build/workload helpers.

Bicep provisions static resources in `rg-<prefix>` (Arc/Monitor) and
`rg-<prefix>-infra` (backing/optional compute). The wrapper handles DCR table
readiness/retries, NAT, Arc onboarding, supported extensions/DCRAs and workbooks.
Linux AMA and CT use VM extensions but Arc DCRAs. Windows VM Insights map is
supported by the lab; Linux map remains disabled. Runtime errors stop deployment
rather than printing a false success.

### Existing estates and partial failures

Do not deploy over an in-use estate just to test a code change. First collect
read-only readiness and propose the exact required reconciliation.
Preserve subscription deployment history while the estate exists: it is the
lifecycle manifest. After `Remove-ArcDemo` the infra group is gone, so Deploy ignores
the stale manifest and builds a fresh Key Vault; `Remove-ArcDemo.ps1
-PruneDeploymentHistory` (opt-in) deletes this demo's own old records.
Incremental optional-only deployments do not delete earlier Arc hosts.

`Deploy-ArcDemo.ps1` does not regenerate VM credentials on a routine redeploy. Reuse the existing
Key Vault secret; old labs without it must supply their **current**
`-AdminPassword` as a SecureString. New Arc onboarding needs no supplied secret:
Deploy ensures an existing SP's Arc-group role and uses a one-day credential it
removes afterwards (see [credentials](lifecycle.md#credentials-and-partial-deployments));
no routine SP credential reset. Resolve missing VM credentials with the
operator, never silently rotate them. The VM password is an estate-deployment
input, not a nested-build prerequisite: the
[nested build](nested-sql-demo.md) needs no vault and uses the same one-day
credential flow.

Match the effective disk tier too: fresh deployments default to SSD, but an
existing HDD lab requires `-OsDiskStorageAccountType Standard_LRS` or that value
in its private skin. The wrapper refuses mismatches even during preview; it
does not convert disks. Preserve the operator-chosen HDD tier and plan any
migration separately before HDD OS support retirement. See [cost.md](cost.md).

## 4. Validate, then rehearse

```powershell
.\scripts\Test-ArcDemoReadiness.ps1 @target -DesiredState Ready -OutputFormat Json -TimeoutSeconds 600
$LASTEXITCODE
```

Exit 0 means required infrastructure/monitor checks pass, 1 is fail/error, 2 is
still pending. Save the timestamped JSON outside source. Check policy, Defender,
Update Manager assessment completion, CT inventory and optional workload behavior
in their own surfaces; a provisioned extension is not proof of telemetry or
completed assessment. Policy scores and CT cycles may take substantially longer
than infrastructure provisioning.

For Linux, inspect direct sensor health separately from MDE extension state.
The approved diagnostics found healthy/licensed sensors in passive mode with
real-time protection disabled, and retained an extension/direct-health
event-provider discrepancy. A Monitor pass is not active AV or full EDR proof.

Rehearse the [20-30 minute Arc/Monitor story](runsheet.md). The optional companion
SRE repo consumes these existing alerts; it does not replace the standalone Arc
operations plane. Reset/induce faults only as separately authorized scenario
actions. Do not claim Arc SQL validation; see [SQL stance](sql-arc-spike.md).

## 5. Park and wake (separate disruptive approval)

```powershell
.\scripts\Hibernate-ArcDemo.ps1 @target -WhatIf
.\scripts\Hibernate-ArcDemo.ps1 @target
.\scripts\Test-ArcDemoReadiness.ps1 @target -DesiredState Hibernated
.\scripts\Activate-ArcDemo.ps1 @target -WhatIf
.\scripts\Activate-ArcDemo.ps1 @target
```

Hibernation parks all VM/AKS/Container App compute in the explicitly targeted demo
infra group, even if deployment manifests, OS metadata or skin drift; drift warns.
It verifies deallocation/AKS stop/inactive revisions before safe NAT/PIP removal.
Foreign/shared bindings skip only networking with a loud residual-cost warning.
Data, identities and fault flags remain. Failed compute attempts do not block
attempts on other hosts/workloads; unknown/denied final power is not success.
Activation restores outbound NAT first, then starts retained workloads. Every run
verifies the hosts, including already-connected ones, without restarting anything:
one shared wait with a 12-minute global deadline (`-GuestCheckMinutes`) passes a host
when its VM is running, Arc is `Connected` and, for a monitored host, a Heartbeat was
generated after the VM start. No Run Command is used for host checks by default, so a
VM extension update that is still `Updating` (a warning, never a gate) cannot stall the
wake; expect about 12-15 minutes. A host with no Heartbeat at the deadline is pending
for that host only; a stopped VM or an Arc identity that never connects fails. Opt in
to Run Command guest checks with `-GuestChecks WhenStalled|Always` (Windows Arc
`himds`/`MonAgentCore`, Linux services) and to service restarts with
`-RepairStalledAgents`; both share the same deadline. The nested SQL guest start keeps
its Run Command concurrently with a five-minute budget. Per-host evidence records
`method`, `startedAtUtc`, `lastHeartbeatUtc` and `extensionStates`.
Telemetry-only pending does not fail activation, but must be rechecked through
readiness before the presentation or dependent SRE/incident-offer flow continues.
Default assessment submissions cover newly started/waking Arc hosts only;
already-active retries do not resubmit. `-AssessPatches` explicitly requests
all-host assessments (including assessment-phase retries). Use optional `-ResultPath`
in an existing private directory to preserve per-host outcomes, and distinguish
script completion from Monitor Ready and asynchronous assessment completion.
It does not reset faults. Optional AKS can take longer and
requires a 15-30 minute stop/start separation; capacity is not guaranteed.
Nightly VM auto-shutdown is not whole-lab hibernation.

Retain runtime target/skin/fleet inputs and deployment history outside git.
If SRE is attached, park that dependent layer first through its own maintained
procedure; on wake, restore Arc/Monitor and verify Ready before SRE resumes.
Hibernation is not cleanup: it does not delete groups, disks, Arc identities,
Key Vault secrets, onboarding credentials, DCRs or the workspace.
Its required acceptance covers parked compute/app state; NAT/PIP absence is a
non-required cost diagnostic. Exit 0 can therefore coexist with incomplete
network cleanup. Retained monitoring is not queried as a parking gate; actual
inspection/auth errors still fail rather than being misreported as absence.
Use normal lifecycle `-WhatIf`, not deployment Graph/Owner/quota preflight or
historical whole-group index comparisons. Exact network sharing is checked
before network writes. On partial failure, retry without redeploying or waking compute.
Enabled alerts can still evaluate/notify and incur charges; there is no automatic
pause/restore of their previous enabled state.

## 6. Remove permanently (separate destructive approval)

```powershell
.\scripts\Remove-ArcDemo.ps1 @target -WhatIf
.\scripts\Remove-ArcDemo.ps1 @target
.\scripts\Test-ArcDemoReadiness.ps1 @target -DesiredState Removed -OutputFormat Json
```

This deletes both demo groups and named policies/budget and verifies all their
absence. A running nested parent gets one bounded graceful guest stop that warns
and continues if it fails. Two opt-in switches serve an intended clean same-prefix
rebuild: `-ForceDeleteWorkspace` first permanently deletes `law-<prefix>` (irreversible;
otherwise re-creating that name within 14 days recovers the old workspace and its
data) and `-PruneDeploymentHistory` deletes this demo's own old `arc-demo-<timestamp>`
deployment records after removal is verified. Defender pricing is preserved unless `-DisableDefender` is explicitly
requested. `-RemoveOnboardingIdentity` is separately opt-in and rejects shared or
ambiguous identities. Inspect remaining subscription/tenant resources and delayed
billing; do not promise zero charges just because group deletion completed.
Default Removed verification needs no deployment history or Graph lookup;
tenant identities/applications, shared services and soft-deleted vaults are
explicit exclusions. Active readiness also accepts the legacy `Ready` name.

## 7. Local development validation

```powershell
Invoke-ScriptAnalyzer -Path .\scripts -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path .\tests -CI
az bicep build --file .\bicep\main.bicep --stdout > $null
```

Pester is development-only, installed in CI; it is not a deployment dependency.
Fresh deploy, double deploy, park/wake and teardown/recreate remain separate
live smoke tests needing a disposable lab and explicit approval. See
[troubleshooting](troubleshooting.md) for known failure modes.
The [dated retained-estate wake/park evidence](nested-sql-demo.md) does not prove
fresh deployment, double-deploy idempotency, AKS lifecycle or full teardown/rebuild.
