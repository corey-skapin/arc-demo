# Arc demo module map

**Engineering reference, not presenter reading.** This is the maintained surface map;
source and mocked tests do not prove current health. Line numbers are intentionally omitted
because they become stale as the scripts evolve. For safe operations and the
readiness contract, see [lifecycle.md](lifecycle.md).

## Infrastructure

| Surface | Responsibility |
| --- | --- |
| `bicep/main.bicep` | Subscription entry point; two resource groups, data-driven onPremFleet, independent optional-workload flags, resource/manifest outputs including AKS cluster IDs |
| `bicep/modules/vm.bicep` | Caller-defined Windows/Linux VM, optional per-entry security type and standalone data disks (attached, never recreated), system identity, NIC, DevTestLab shutdown schedule |
| `bicep/modules/azure-vms.bicep` | Optional Azure-native Windows VM, native AMA/Dependency Agent; never Arc-onboarded |
| `bicep/modules/container-apps.bicep` | Optional consumption Container App, fault flag, restart alert |
| `bicep/modules/aks.bicep` | Optional AKS, Container Insights, managed deployment-script identity, sample workload and restart alert |
| `bicep/modules/network.bicep` | VNet/subnet/NSG; creates fresh NAT/PIP before compute or preserves the existing NAT attachment |
| `bicep/modules/keyvault.bicep` | Shared admin-credential vault and deployer RBAC |
| `bicep/modules/workspace.bicep` | Log Analytics and VMInsights/ChangeTracking solutions |
| `bicep/modules/dcrs.bicep` | Deterministic DCR IDs; `New-CoreDcrBody` in the deploy wrapper owns selectors, including the source/event-specific LOB informational heartbeat |
| `bicep/modules/alerts.bicep` | Action Group and missing-Heartbeat alert |
| `bicep/modules/defender.bicep`, `tests/DefenderPlan.Tests.ps1` | Subscription Defender for Servers P2, deployed only while the live plan is not already Standard (`deployDefenderVmPlan`, set by Deploy); an enabled plan and its extensions are never re-PUT |
| `bicep/modules/policy.bicep` | Named MCSB/NIST assignments |
| `bicep/modules/budget.bicep` | Named budget filtered to demo RGs, notification thresholds |
| `bicep/modules/operational-workbook.bicep` | Optional standalone shared workbook only (a published copy or a separately marked draft); existing workspace, deterministic owned ID, no workload/telemetry changes |

Fresh deployment creates NAT/PIP; hibernation deletes them and activation
recreates them. A routine Bicep rerun preserves an existing gateway. The backing compute is an Azure-hosted simulation;
the customer-facing Arc records and observability plane are in the other group.

## Operations

| Entry point | Responsibility |
| --- | --- |
| `scripts/Test-Prerequisites.ps1` | Read-only tools/context/effective permissions and the providers/CLI extensions the skin's workload toggles need (`Get-DemoPrerequisiteSet`, shared with Deploy and the wrapper's P0); reports every gap in one error, installs/registers nothing |
| `scripts/New-NestedSqlDemoGuest.ps1`, `Connect-NestedSqlDemoGuest.ps1`, `Install-NestedSqlDemoEngine.ps1` | Primary scratch Windows/SQL/Arc guest build; private credentials and approved media |
| `scripts/New-NestedSqlDemo.ps1`, `Invoke-NestedSqlDemoStep.ps1`, `scripts/lib/NestedSqlDemo.psm1` | Working build sequence (its onboarding credential comes from the shared identity helper), protected parent-side step transport and retained Windows answer-file generator; no retired V1-V3 controller layers |
| `scripts/Test-NestedSqlDemoGuest.ps1`, `Enable-NestedSqlDemoExtension.ps1`, `Remove-NestedSqlDemoGuest.ps1` | Actual guest/SQL checks, Arc SQL extension and explicit scratch-guest teardown |
| `scripts/Install-ArcSqlDemoExtension.ps1`, `Test-ArcSqlDemoInventory.ps1`, `Remove-NestedSqlDemo.ps1` | LicenseOnly extension, actual Azure SQL/database inventory and exact guest/Arc/SQL teardown |
| `scripts/Set-NestedSqlDemoState.ps1` | Optional parent/guest-only park/wake, using the same skin and Common guest helper; retains shared network and other workloads |
| `scripts/Stage-DemoMedia.ps1`, `scripts/guest/Save-DemoMedia.ps1`, `config/demo-media.json`, `tests/DemoMedia.Tests.ps1` | Pinned public Microsoft installer media (Windows Server 2022 Evaluation, SQL Server 2022 Developer): resumable `curl.exe` download on a running lab Windows VM, exact size and SHA-256 before the final name, no overwrite of a mismatching file, explicit terms switches recorded in a private acceptance file; used for the nested parent and `win-sql-01`'s SQL ISO |
| `Invoke-DemoGuestAction`, `Get-DemoGuestTarget`, `Get-DemoMediaManifest` in `Common.psm1` | Run one action of a repo guest script (`scripts/guest/`, Windows PowerShell 5.1) through classic Run Command with base64 settings and one structured result line; resolve one retained Windows VM from the exact inventory; load the validated media manifest |
| `scripts/Prepare-NestedSqlParent.ps1`, `scripts/guest/Initialize-NestedSqlParentHost.ps1`, `tests/NestedSqlParentPrepare.Tests.ps1` | One idempotent, `-WhatIf`-capable run that prepares the nested SQL parent once Deploy has declared its size and data disk: Size, Disk, Volume (`D:`; the empty virtual DVD-ROM that a size without a temp disk puts there moves to `Z:`), HyperV (restart issued from Azure), Network (internal switch and NAT), Media (through `Stage-DemoMedia.ps1`) and a Verify that writes the build input for `New-NestedSqlDemo.ps1`. Refuses any other `D:` holder, an overlapping range, Trusted Launch, a running nested guest and any unsafe disk change. Tested against a simulated Azure/guest world and rehearsed end to end, with a park/wake check, on a scratch `Standard_D4s_v5` (not yet through Deploy or on an Arc-onboarded parent) |
| `.github/workflows/lint.yml` Windows job | Executes nested guest and real SQL regressions with mocked Windows APIs |
| `scripts/Deploy-ArcDemo.ps1` | Selected-provider/CLI-extension and per-size SKU/quota checks (one `-Requirements` call covers every size); refuses to resize a retained VM or detach/convert its data disks; declares the nested parent's size and disk from the skin; stale-manifest handling after Remove; Bicep preview/create with allocation-failure guidance (never a size/region switch); retrying Key Vault secret write; preserve credentials/faults; NAT; Arc onboarding; checked extension jobs; DCRAs; workbook upsert; required infrastructure/monitor readiness (waits up to 20 minutes for Windows Heartbeats) |
| `scripts/New-PresenterRunsheet.ps1` | Offline `.local` context validation and concrete presenter links/KQL (including the optional nested guest, LOB alert, data collection rule and the Machine Intelligence, Compliance, Asset Inventory and SQL Estate workbook links) from the single tracked `docs/runsheet.md` template; with `-SreGuidePath` it also writes `.local/full-demo-runsheet.md` (whole-demo table, the Arc guide, the SRE guide's own text as "The night shift (SRE half)" and one close); no Azure calls or lifecycle changes |
| `scripts/Activate-ArcDemo.ps1` | Explicit target, retained manifests, restore NAT/start workloads, one shared Heartbeat/Arc/ARM wait with a single global deadline (no Run Command host checks by default; opt-in `-GuestChecks`), concurrent nested-guest start, leave explicitly configured unused parents deallocated, optional asynchronous patch submission, readiness |
| `scripts/Hibernate-ArcDemo.ps1` | Best-effort all-compute parking inside the explicit infra RG despite manifest/skin drift; safe NAT cleanup afterward; retains faults/data |
| `scripts/Remove-ArcDemo.ps1` | Named policy/budget and group deletion with bounded completion; bounded nested-guest stop that warns and continues; optional identity/Defender changes, `-ForceDeleteWorkspace` (first, irreversible) and `-PruneDeploymentHistory` (own manifest records only) |
| `scripts/Test-ArcDemoReadiness.ps1` | Read-only JSON v1/Table; Active (Ready alias), compute-only Hibernated with network cost diagnostics, Removed; bounded retries, exit 0/1/2 |
| `scripts/lib/Common.psm1` | Skin/fleet validation (optional per-entry size, security type, data disks), checked CLI/REST with subscription pinning, tenant-only directory guards and CLI 2.91 not-found text, retained inventory, retained VM size/disk guards and per-size demand, bounded waits/jobs, the shared host-readiness wait (`Wait-DemoHostsReady`: one Heartbeat query, parallel time-boxed ARM reads, opt-in guest-check script), `@file` guest-script transport/markers, capacity/quota (CLI string quotas read as numbers; `-Requirements` adds several sizes per family), allocation guidance, retrying Key Vault secret write, stale-manifest selection, readiness checks |
| `Get-DemoNestedSqlGuestConfig`, `Invoke-DemoNestedSqlGuest`, `Wait-DemoNestedSqlArcConnected` in `Common.psm1`, `tests/NestedSqlLifecycle.Tests.ps1` | One skin-defined nested guest, normal graceful shutdown/start and bounded Arc connection wait across Activate/Hibernate/Remove |
| `Initialize-DemoOnboardingIdentity`, `Invoke-DemoOnboardingCredential` and the Graph helpers in `Common.psm1`, `tests/OnboardingIdentity.Tests.ps1` | Shared by Deploy and the nested build: an existing onboarding SP keeps its credentials, its Arc-group role is ensured after the group exists, a one-day credential is minted through Graph, passed as a SecureString and removed in `finally` with the original key IDs verified; with no SP it is created with the role and nothing is stored |
| `New-DemoArcLinuxOnboardScript`, `Get-DemoArcTestServiceEnvScript` in `Common.psm1`, `tests/LinuxArcOnboard.Tests.ps1` | Linux Arc onboarding script, always LF: `MSFT_ARC_TEST` for `azcmagent connect` plus a persistent systemd drop-in for `himdsd`, `extd` and `gcad` (best-effort restart of `extd`/`gcad` after connect). The drop-in step is idempotent and is also the one-off fix for a host onboarded by an older Deploy. Checked with `bash -n`; not yet run on a Linux host |
| `scripts/Invoke-SqlWorkloadOnArc.ps1` | Separate SQL-shaped guest signal simulator; not SQL Server enabled by Azure Arc validation |
| `scripts/Invoke-SqlEngineOnArc.ps1`, `samples/sql-engine/SqlEngineDemo.ps1` | Explicit one-host real SQL 2022 Developer installation/status/worker operations; approved media/terms, bounded startup and hash ownership; guarded emitter-only update preserves normal worker functions and migrates the owned checkpoint with rollback/backups; no Arc SQL, automatic reboot/repair or Defender changes |
| `scripts/Set-SqlIncidentAlert.ps1`, `bicep/modules/sql-incident-alert.bicep` | Optional exact-host Sev2 real lock-timeout alert on existing LAW/Action Group; v2 actual error/wait/session evidence, bounded rollback and independently gated recovery, not synthetic proof or SRE remediation |
| `scripts/Set-ArcWorkloadAlertDescription.ps1` | Narrow existing-canonical SQL/LOB description-only PATCH/readback; preserves titles, queries, settings, scopes, routes and tags; no DCR, guest or receiver changes |
| `scripts/Set-OperationalWorkbook.ps1`, `scripts/lib/OperationalWorkbooks.psm1`, `workbooks/operational-layout.json` | Default read-only preview, scoped approved publication, separate draft copies and draft-only removal; exact bounded Arc roster, config-driven nested guest from the skin plus optional declared topology, ownership/draft guards, shared-query composer, the portal layout pass (grid widths and formats, sizes, column charts, tiles) driven by the layout file, and offline scenario reference; no lifecycle/collection actions |
| `scripts/Invoke-ArcDemoBuild.ps1`, `scripts/lib/BuildPlan.psm1`, `config/build-plan.example.json` | Thin ordered wrapper (P0-P11) over the maintained scripts: plan only by default, explicit switches for first spend, licences, SRE parent creation and the opt-in alert-access grant, per-step resume state and evidence in the private folder, no deployment logic of its own |
| `scripts/Export-ArcDemoInventory.ps1`, `scripts/Test-ArcDemoParity.ps1`, `scripts/lib/EstateSnapshot.psm1`, `config/expected-inventory.json` | Read-only JSON snapshot (denied reads recorded, no secrets) and a parity check of the expected objects and the manifest fleet; exit 0/1 |

All four lifecycle/deployment scripts require explicit subscription/tenant and
support ShouldProcess. Missing explicitly supplied skins are errors except approved parking with an
explicit confirmed prefix.
`-WhatIf` has no Azure mutation side effects. Successful subscription deployment
history is retained as the per-workload manifest: additive empty-fleet deployments
do not hide earlier Arc VMs. Unknown VMs fail closed for startup/deletion, not
spend-reducing parking. Foreign IDs always fail closed. Hibernated readiness
queries cost state, not retained monitoring; NAT/PIP cost diagnostics do not gate
verified compute parking. The host wait uses one Heartbeat query and ARM state, not
Run Command, under one deadline with per-host pending evidence; telemetry-only lag
requires a readiness recheck, not repair.

## Monitoring support

Default fleet: five Windows Server 2016/2019/2022 hosts and three Ubuntu 22.04
hosts. Capability booleans, not names/counts, determine payloads.

| Fleet subset | Extension path | DCRA scope |
| --- | --- | --- |
| Supported Arc Windows | Arc AMA, Windows Dependency Agent, Windows CT | Arc machine ID |
| Supported lab Linux | Azure VM AMA and CT; no Dependency Agent/map | Arc machine ID |
| Optional native Windows | Azure VM AMA/Dependency Agent | Azure VM ID |
| Arc-control-plane-only tier | No unsupported Monitor payload | No Monitor DCRA |

Resource existence/provisioning is different from guest health, data arrival,
policy compliance and patch completion. The readiness contract states exactly
what is checked. No live full teardown/recreate or double-deploy claim follows
from local mocked tests.
The inspected Linux sensors' healthy/licensed passive-mode state is not proof of
active antivirus or complete EDR; preserve the event-provider/direct-health
discrepancy described in [lifecycle.md](lifecycle.md).

## Configuration, story and validation

`config/demo-skin.json` supplies customer labels, lowercase prefix/region,
workload flags, notification email, tags, schedule and budget threshold;
`config/dummy-customer.demo-skin.json` is the non-default example. Runtime
arguments override skin values. Do not commit subscription/tenant IDs or secrets.
Fleet paths resolve from repo root. Optional-workload templates may retain
intentional sample names; lifecycle follows IDs rather than guessing those names.

`workbooks/arc-demo-overview.workbook.json` is a static, self-contained template (no
deploy-time tokens), so Phase 11 publishes it as is, apart from pinning its Log Analytics
items to the deployment workspace; it reads the Arc inventory
through `arg("")` inside its Log Analytics queries and takes its filter options from
Resource Graph. It and the vendored `workbooks/nseilaz` collection provide the presenter
surfaces. `docs/runsheet.md` keeps the
25-28 minute standalone Arc/Monitor story, "the Monday-morning questions", in seven
chapters that follow one SQL database (estate, one server's evidence for Windows and
Linux alike, compliance and updates, SQL under one view including the experimental
nested Arc SQL guest, the two engineer workbooks and the alert rules), with a hook,
a close, prepared answers for disaster recovery and migration, and 20 and 15 minute
cut lists. SRE Agent is an optional later layer
consuming the same alerts, not a prerequisite or replacement.
`tests/OriginalWorkbooks.Tests.ps1` keeps the six original workbooks valid and
demo-ready offline: JSON and title checks, subscription-picker defaults, the lab's
tag names and the Compliance patch tiles. `tests/EstateOverviewWorkbook.Tests.ps1`
covers the Estate Overview's own behaviour (see the
[workbook reference](operational-workbooks.md#estate-overview-chapter-1)).
`tests/RunsheetWorkbookNames.Tests.ps1` is the name guard: every bold tile, section or tab
name in a chapter of the template must exist in the workbook that chapter opens.
`workbooks/arc-asset-inventory.workbook.json`, `workbooks/arc-compliance.workbook.json` and
`workbooks/arc-governance.workbook.json` are the rebuilt asset inventory, compliance and (experimental)
governance workbooks. Phase 11 (`Set-WorkbookWorkspaceDefaults`) pins every Log Analytics item of
the workbooks it publishes to the deployment workspace, so the repo JSON carries no workspace id, and
`tests/AssetInventoryWorkbook.Tests.ps1`, `tests/ComplianceWorkbook.Tests.ps1`,
`tests/GovernanceWorkbook.Tests.ps1` and `tests/WorkbookWorkspaceScope.Tests.ps1` guard them, and
`tests/RebuiltWorkbooksLayout.Tests.ps1` guards what only shows in the portal (grid columns in proportional `fr`
widths that add up to at most 115 characters, so a grid fits its container instead of pushing columns off
screen, with each header fitting its column; date/time columns in local time and wide enough for the AM/PM;
percentage columns as solid red, amber and green cells printed with a % sign (a heat-map cell puts dark text on dark red); small grids that fit their rows instead of reserving a fixed 330 px
band; grouped bar charts that name their category column; percentage charts on a 0 to 100 axis with a % unit;
chart legends without the `(Sum)` totals that page through the categories; a positive empty state in the green
success style (3) instead of the amber warning triangle (4)). Count tiles in the three rebuilt workbooks carry no palette colour,
because the auto palette colours by position and a failing count could read teal or a passing one purple;
red-to-green colour comes only from the percentage tiles and the status icons.
Resource Graph allows at most two tables per query and never the security and patch tables together, so the
compliance tiles are one query per table pair.

`tests/MachineIntelligenceWorkbook.Tests.ps1` and `tests/SqlEstateWorkbook.Tests.ps1` guard the two reworked
engineer workbooks offline: defaults and a no-click open, no workspace picker, a specific message for
every empty tile, tile text lengths, formatter columns and colour direction, and the honest SQL
labelling (experimental, no Defender claim, guarded best practices assessment).

`workbooks/capacity-headroom.workbook.json`,
`workbooks/optimisation-opportunities.workbook.json` and the shared
`workbooks/queries/*.kql` (fragments `operational-*.kql` plus the `cap-*`, `opt-*` and
`detail-*` items) provide optional existing-telemetry review; see the
[workbook reference](operational-workbooks.md). The JSON files are templates the module
renders with the exact roster, so the same evidence logic serves both workbooks.
The single presenter template accepts actual published optional links; missing
or stale telemetry stays explicit and parent/guest rows are never totalled.
`tests/OperationalWorkbooks.Tests.ps1` covers rendering, scoping, roster/topology,
draft and scenario behavior; `tests/OperationalWorkbooksLayout.Tests.ps1` guards the
portal layout (fr widths, Full-size bounded tables, number and time formats, column
charts with null gaps, colourless tiles) and the layout pass's refusals;
`tests/OperationalWorkbookQueries.Tests.ps1`
explicitly opts into read-only execution of the production item queries against
deterministic literal-table fixtures (`tests/fixtures/operational-telemetry.kql`),
not a live fault or ingestion.

`tests/Lifecycle.Tests.ps1` exercises waits, errors, config, mixed/native
classification, retained additive manifests, ShouldProcess previews, guest/job
failures and the JSON/exit-code contract without a cloud deployment.
`tests/GuestReadinessWait.Tests.ps1` covers the shared Activate wait on a simulated
clock: all-fresh Heartbeats with Updating extensions, one pending host, deadline
bounds for nine hosts, no Run Command by default, opt-in checks, the nested guest
budget and the soft extension readiness rows.
`tests/DeployRemoveHardening.Tests.ps1` covers, with CLI-2.91-shaped string
fixtures and mocked Azure, the capacity check, extension/provider preflight,
CLI not-found text, clean-subscription and stale-manifest Deploy, Key Vault write
retry, allocation guidance and the Remove workspace/history options.
`tests/FleetVmShape.Tests.ps1` covers the optional per-entry size/security/disk
schema, the skin-declared nested parent, retained size/disk refusal and per-size
capacity demand, including the Deploy preview wiring.
`tests/LinuxArcOnboard.Tests.ps1` renders the Linux onboarding script and checks the
daemon drop-ins, their order around `azcmagent connect`, LF line endings and `bash -n`.
`tests/BuildPlan.Tests.ps1` covers the build wrapper's config, plan, approvals,
resume state, runner and presenter handoff with stub scripts;
`tests/EstateParity.Tests.ps1` covers snapshot collection (read-only calls, recorded
denials) and the parity rules, both without Azure.
Skin JSON uses PowerShell's native `-AsHashtable`; the redundant recursive
conversion helper is removed rather than adding another abstraction.
`.github/workflows/lint.yml` runs PSScriptAnalyzer, parsing/Pester, Bicep compile
and advisory documentation lint. Inspect the Markdown log rather than treating
the job's success alone as lint-clean. Pester is development-only.
