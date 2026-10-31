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
|---|---|
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
| `capacityWorkbookResourceId`, `optimisationWorkbookResourceId` (optional) | Actual published IDs from the scoped [operational workbook setup](#optional-capacity-and-optimisation-workbooks); never preview IDs. Adds optional links, not current-health or savings proof |
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
They reuse existing `Perf`/`InsightsMetrics` and Arc inventory; no collection,
retention, guest, SQL, extension, power, price or schedule changes are made.
DR and Azure Migrate assessment are outside this demo.

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
# Actual publication is a separate approved operation, confirmed by ShouldProcess.
.\scripts\Set-OperationalWorkbook.ps1 @workbookTarget -Purpose capacity -Action Deploy
.\scripts\Set-OperationalWorkbook.ps1 @workbookTarget -Purpose optimisation -Action Deploy
```

Only the selected shared workbook is created/updated by the small Bicep module,
with an exact-content readback. Stable IDs are derived from workspace/purpose;
a foreign existing workbook is never adopted. No whole-lab deployment, IAM or
repair is used. Workbooks survive parking with the workspace, contain no active
jobs and disappear with the Arc group on approved normal removal. Existing
lifecycle/readiness gates are unchanged. Re-publishing changed source or
refreshing roster/topology requires new approval, not an incidental wake.

**Coverage before conclusions:** each grid starts with every selected Arc ID,
including hosts without samples. CPU is only total CPU, not a blend of per-core
rows or duplicate `Processor`/`Processor Information` streams. `Perf` is preferred
for CPU/memory, with supported existing VM Insights values as fallback; per-volume
VM Insights disk data is preferred to `_Total` aggregate free-space evidence.
One canonical source is selected per host/metric across the window, not mixed
to conceal source gaps. Source names, first/last timestamps, observed-minute
coverage and min/mean/P95/max remain visible. Missing values are null, not zero;
invalid samples warn. Hourly trends omit absent hours instead of filling zeros.
Disk Delta is first-to-last percentage points, not a growth forecast.

Coverage is observed one-minute bins divided by elapsed-window minute bins,
including parking; it is not uptime, expected online time or an agent SLA.
The default window is seven days, with 24-hour/30-day choices. More than
15 minutes stale, less than 24 hours between samples, or less than 80% coverage
prevents a low-CPU conversation candidate. A 24-hour window can deliberately
remain insufficient because its first-to-last sample span is shorter than
24 hours. The query control's fixed 30-day transport scope encloses all three
KQL windows; it does not silently clip seven-day analysis to a 24-hour default.
Low CPU alone never yields a sizing recommendation. SQL host telemetry
does not establish engine capacity, database performance or licence needs.
Pressure thresholds (CPU max 90%, committed memory max 85%, available memory
min 512 MB, disk free min 15%) are explainable triage heuristics, not universal
right-sizing or availability guarantees.

The inspected existing demo collection provided total CPU for Windows and Linux,
but memory/committed-memory/disk `Perf` and per-volume VM Insights evidence only
for Windows. Configured Linux memory/disk counters did **not** prove actual
samples. Preserve that missing-data warning; do not broaden collection to make
the view green. These are dated engineering observations, not today's health.

**Topology and ownership:** the roster contains exact Arc IDs only, never their
Azure backing-VM duplicates. New/nested hosts are not silently included;
refresh after separately approved onboarding. All layers default to
`unclassified`; names do not prove parent/guest relationships. Optional private
`-TopologyPath` JSON is `{"schemaVersion":1,"machines":[...]}`; each entry has
`resourceId`, `layer` (`parent`, `guest` or `standalone`) and, for guests only,
`parentResourceId` referencing another selected, explicitly classified parent.
This declares a relationship, not physical hardware capacity. No hardware totals
are calculated; never add guest and parent measurements. The optimisation view
reads current `owner`/`costcenter`/`role` tags through Resource Graph for those
exact IDs. Empty/missing ARG results are missing inventory evidence, not proof
that a resource or owner is absent; query failures must be reported.

Optional operator assumptions `-HypotheticalHourlyRate`,
`-HypotheticalWeeklyHoursOff` (0-168) and `-HypotheticalMachineResourceId` require
one explicitly classified parent/standalone resource and positive inputs.
No guest, inferred currency, price API or estate multiplication is used.
`rate x hours/week x 4 weeks` is explicitly hypothetical compute-only currency
units, **not** a calendar month, billed/realised savings, a safe shutdown schedule
or an all-in cost. Disks/network/monitoring/security/commitments/licences and
other retained costs remain outside that illustration. With no inputs it stays
unconfigured. No stop/delete/schedule buttons or resource actions are provided.

After actual publication, save only the returned published workbook IDs as the
optional context fields above and regenerate the existing presenter guide.
Do not add preview IDs or claim portal rendering has been observed from source
validation alone. Documented workbook deployment and scope conventions:
[programmatic workbooks](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-automate)
and [workbook resource templates](https://learn.microsoft.com/azure/templates/microsoft.insights/2023-06-01/workbooks).

Local Pester covers rendering, scope/ownership/preview guards and decimal scenario
arithmetic. `tests/OperationalWorkbookQueries.Tests.ps1` is deliberately opt-in:
pass explicit workspace/subscription/tenant via `New-PesterContainer -Data` to
execute deterministic literal-table KQL fixtures read-only. It ingests nothing,
touches no guests and tests the actual production query logic for spikes,
pressure, missing/invalid samples, parked gaps, short histories and separate
parent/guest rows. Normal CI skips those Azure-dependent tests; a local mock
pass does not imply KQL execution or a published workbook.

## 1. Choose the target and skin

Use a demo subscription where the operator has effective subscription Owner or
Contributor plus User Access Administrator, and permission to create an Arc
onboarding identity if needed. PowerShell 7.4+, Azure CLI 2.60+ and Bicep are
required. No Az PowerShell module, production framework or SRE Agent is required.

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

Preflight does not register providers or change context. Resolve any missing
provider with separate operator authorization, using the exact providers reported
by deployment preflight for the selected workloads. Supplying
`-DeployerPrincipalId <OBJECT_ID>` bypasses only Graph user discovery, not RBAC.
SKU restriction and regional/family vCPU quota checks do not guarantee capacity.
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
The retired mixed `-InstallSql` path fails rather than enabling Arc SQL/BPA.

Bicep provisions static resources in `rg-<prefix>` (Arc/Monitor) and
`rg-<prefix>-infra` (backing/optional compute). The wrapper handles DCR table
readiness/retries, NAT, Arc onboarding, supported extensions/DCRAs and workbooks.
Linux AMA and CT use VM extensions but Arc DCRAs. Windows VM Insights map is
supported by the lab; Linux map remains disabled. Runtime errors stop deployment
rather than printing a false success.

### Existing estates and partial failures

Do not deploy over an in-use estate just to test a code change. First collect
read-only readiness and propose the exact required reconciliation.
Preserve subscription deployment history: it is the lifecycle manifest.
Incremental optional-only deployments do not delete earlier Arc hosts.

VM credentials are not regenerated on a routine redeploy. Reuse the existing
Key Vault secret; old labs without it must supply their **current**
`-AdminPassword` as a SecureString. New Arc onboarding with an existing SP
requires its existing `-OnboardingSecret`; no routine SP credential reset.
Resolve missing credentials with the operator, never silently rotate them.

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
Activation restores outbound NAT first, starts retained workloads and reconnects
agents where needed. Every run verifies guests, including already-connected hosts,
without unnecessary restarts; Windows Arc AMA uses a `MonAgentCore` process check.
Host checks run concurrently with a ten-minute AMA budget and per-host evidence.
An AMA timeout records pending; required service failures still fail.
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
absence. Defender pricing is preserved unless `-DisableDefender` is explicitly
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
The approved eight-host active/readiness proof is not evidence that these
separate deployment or lifecycle cycles have been exercised.
