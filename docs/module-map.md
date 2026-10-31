# Arc demo module map

**Engineering reference, not presenter reading.** This is the maintained surface map;
source and mocked tests do not prove current health. Line numbers are intentionally omitted
because they become stale as the scripts evolve. For safe operations and the
readiness contract, see [lifecycle.md](lifecycle.md).

## Infrastructure

| Surface | Responsibility |
|---|---|
| `bicep/main.bicep` | Subscription entry point; two resource groups, data-driven onPremFleet, independent optional-workload flags, resource/manifest outputs including AKS cluster IDs |
| `bicep/modules/vm.bicep` | Caller-defined Windows/Linux VM, system identity, NIC, DevTestLab shutdown schedule |
| `bicep/modules/azure-vms.bicep` | Optional Azure-native Windows VM, native AMA/Dependency Agent; never Arc-onboarded |
| `bicep/modules/container-apps.bicep` | Optional consumption Container App, fault flag, restart alert |
| `bicep/modules/aks.bicep` | Optional AKS, Container Insights, managed deployment-script identity, sample workload and restart alert |
| `bicep/modules/network.bicep` | VNet/subnet/NSG; creates fresh NAT/PIP before compute or preserves the existing NAT attachment |
| `bicep/modules/keyvault.bicep` | Shared admin-credential vault and deployer RBAC |
| `bicep/modules/private-onboarding-vault.bicep`, `private-secret-placeholder.bicep` | Separately approved existing-estate private endpoint/DNS and exact-secret readers; disabled nonsecret initial scope, never actual credentials in ARM |
| `bicep/modules/workspace.bicep` | Log Analytics and VMInsights/ChangeTracking solutions |
| `bicep/modules/dcrs.bicep` | Deterministic DCR IDs; `New-CoreDcrBody` in the deploy wrapper owns selectors, including the source/event-specific LOB informational heartbeat |
| `bicep/modules/alerts.bicep` | Action Group and missing-Heartbeat alert |
| `bicep/modules/defender.bicep` | Subscription Defender for Servers P2 |
| `bicep/modules/policy.bicep` | Named MCSB/NIST assignments |
| `bicep/modules/budget.bicep` | Named budget filtered to demo RGs, notification thresholds |
| `bicep/modules/operational-workbook.bicep` | Optional standalone shared workbook only; existing workspace, deterministic owned ID, no workload/telemetry changes |

Fresh deployment creates NAT/PIP; hibernation deletes them and activation
recreates them. A routine Bicep rerun preserves an existing gateway. The backing compute is an Azure-hosted simulation;
the customer-facing Arc records and observability plane are in the other group.

## Operations

| Entry point | Responsibility |
|---|---|
| `scripts/Test-Prerequisites.ps1` | Read-only tools/context/effective permissions/baseline provider checks |
| `scripts/New-NestedSqlDemoGuest.ps1`, `Connect-NestedSqlDemoGuest.ps1`, `Install-NestedSqlDemoEngine.ps1` | Primary scratch Windows/SQL/Arc guest build; private credentials and approved media |
| `scripts/New-NestedSqlDemo.ps1`, `Invoke-NestedSqlDemoStep.ps1`, `scripts/lib/NestedSqlDemo.psm1` | Working build sequence, protected parent-side step transport and retained Windows answer-file generator; no retired V1-V3 controller layers |
| `scripts/Test-NestedSqlDemoGuest.ps1`, `Enable-NestedSqlDemoExtension.ps1`, `Remove-NestedSqlDemoGuest.ps1` | Actual guest/SQL checks, Arc SQL extension and explicit scratch-guest teardown |
| `scripts/Install-ArcSqlDemoExtension.ps1`, `Test-ArcSqlDemoInventory.ps1`, `Remove-NestedSqlDemo.ps1` | LicenseOnly extension, actual Azure SQL/database inventory and exact guest/Arc/SQL teardown |
| `scripts/Set-NestedSqlDemoState.ps1` | Optional parent/guest-only park/wake, using the same skin and Common guest helper; retains shared network and other workloads |
| `scripts/Initialize-PrivateOnboarding.ps1`, `scripts/lib/PrivateOnboarding.psm1`, `scripts/guest/Set-PrivateVaultSecret.ps1` | Default read-only preview; one-shot private credential initialization, exact parent/app ownership, protected REST writer, original-key retention and returned-new-key rollback; not guest onboarding or lifecycle/fresh admin bootstrap |
| `tests/PrivateWriterProof.Tests.ps1`, `tests/fixtures/PrivateWriterProof.Ps5Harness.ps1`, `tests/fixtures/PrivateMarker.Ps5Harness.ps1` | Retained private-vault writer regressions; not nested SQL lifecycle prerequisites |
| `scripts/guest/Test-PrivateVaultPath.ps1`, `tests/PrivateFailureDiagnostics.Tests.ps1` | Separately released parent-only `InspectPath` source: immutable compute metadata, pinned private DNS/IP/TCP/hostname-validated TLS, no identity token/secret/role operation; bounded sanitized failure proof saved before terminal cleanup; no automatic initializer resume |
| `tests/PrivatePathPs5.Tests.ps1`, `tests/fixtures/PrivatePath.Ps5Harness.ps1` | Real Windows PS5 native parameter/JSON-array regressions, synthetic metadata/DNS only: shared PS5 nesting defect, quote-free address transport, narrow identity/metadata/input substages; Windows CI required, explicitly skipped on non-Windows |
| `tests/fixtures/PrivateTls.Ps5Harness.ps1` | Actual Inspector TLS/task/deadline blocks under native PS5 using a memory stream and synthetic typed failures: bounded phase, task, exception-kind and native-code evidence; no socket, certificate bypass or live-cause claim |
| `tests/fixtures/PrivateHttp.Ps5Harness.ps1` | Native PS5 request-local TLS1.2 handler/default-validation configuration and real HttpClient message/content/response/disposal mechanics with a synthetic network handler; HTTP denial, redirect and foreign-route rejection, no global protocol or trust mutation |
| `.github/workflows/lint.yml` Windows PS5 job | Executes private-path and retained nested SQL regressions on Windows; mocked tests are not live deployment proof |
| `scripts/Deploy-ArcDemo.ps1` | Selected-provider and SKU/quota checks; Bicep preview/create; preserve credentials/faults; NAT; Arc onboarding; checked extension jobs; DCRAs; workbook upsert; required infrastructure/monitor readiness |
| `scripts/New-PresenterRunsheet.ps1` | Offline `.local` context validation and concrete presenter links/KQL from the single tracked `docs/runsheet.md` template; no Azure calls or lifecycle changes |
| `scripts/Activate-ArcDemo.ps1` | Explicit target, retained manifests, restore NAT/start workloads/reconnect where needed, optional asynchronous patch submission, readiness |
| `scripts/Hibernate-ArcDemo.ps1` | Best-effort all-compute parking inside the explicit infra RG despite manifest/skin drift; safe NAT cleanup afterward; retains faults/data |
| `scripts/Remove-ArcDemo.ps1` | Named policy/budget and group deletion with bounded completion; optional identity/Defender changes |
| `scripts/Test-ArcDemoReadiness.ps1` | Read-only JSON v1/Table; Active (Ready alias), compute-only Hibernated with network cost diagnostics, Removed; bounded retries, exit 0/1/2 |
| `scripts/lib/Common.psm1` | Skin/fleet validation, checked CLI/REST with subscription pinning and tenant-only directory guards, retained inventory, bounded waits/jobs, `@file` guest-script transport/markers, capacity/quota, readiness checks |
| `Get-DemoNestedSqlGuestConfig`, `Invoke-DemoNestedSqlGuest`, `Wait-DemoNestedSqlArcConnected` in `Common.psm1`, `tests/NestedSqlLifecycle.Tests.ps1` | One skin-defined nested guest, normal graceful shutdown/start and bounded Arc connection wait across Activate/Hibernate/Remove |
| `scripts/Invoke-SqlWorkloadOnArc.ps1` | Separate SQL-shaped guest signal simulator; not SQL Server enabled by Azure Arc validation |
| `scripts/Invoke-SqlEngineOnArc.ps1`, `samples/sql-engine/SqlEngineDemo.ps1` | Explicit one-host real SQL 2022 Developer installation/status/worker operations; approved ISO/hash/terms, isolated local instance, bounded database/startup, phase-specific terminal errors and hash-checked worker ownership; no Arc SQL or automatic reboot/repair; independent policy-deployed Defender is not removed or disabled |
| `scripts/Set-SqlIncidentAlert.ps1`, `bicep/modules/sql-incident-alert.bicep` | Optional exact-host Sev2 real lock-timeout alert on existing LAW/Action Group; SQL incident uses owned sessions/probe, rollback and transaction-derived events, not synthetic SQL proof or SRE remediation |
| `scripts/Set-OperationalWorkbook.ps1`, `scripts/lib/OperationalWorkbooks.psm1` | Default read-only preview/scoped approved publication; exact Arc roster, optional declared topology, ownership guards, hypothetical one-resource decimal scenario, no lifecycle/collection actions |

All four lifecycle/deployment scripts require explicit subscription/tenant and
support ShouldProcess. Missing explicitly supplied skins are errors except approved parking with an
explicit confirmed prefix.
`-WhatIf` has no Azure mutation side effects. Successful subscription deployment
history is retained as the per-workload manifest: additive empty-fleet deployments
do not hide earlier Arc VMs. Unknown VMs fail closed for startup/deletion, not
spend-reducing parking. Foreign IDs always fail closed. Hibernated readiness
queries cost state, not retained monitoring; NAT/PIP cost diagnostics do not gate
verified compute parking. Guest checks use concurrent jobs, a ten-minute AMA wait
and pending evidence; telemetry-only lag requires a readiness recheck, not repair.

## Monitoring support

Default fleet: five Windows Server 2016/2019/2022 hosts and three Ubuntu 22.04
hosts. Capability booleans, not names/counts, determine payloads.

| Fleet subset | Extension path | DCRA scope |
|---|---|---|
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

`workbooks/arc-demo-overview.workbook.json` and the vendored `workbooks/nseilaz`
collection provide the presenter surfaces. `docs/runsheet.md` keeps the
20-30 minute standalone Arc/Monitor story. SRE Agent is an optional later layer
consuming the same alerts, not a prerequisite or replacement.

`workbooks/capacity-headroom.workbook.json`,
`workbooks/optimisation-opportunities.workbook.json` and shared
`workbooks/queries/operational-*.kql` provide optional existing-telemetry review.
The single presenter template accepts actual published optional links; missing
or stale telemetry stays explicit and parent/guest rows are never totalled.
`tests/OperationalWorkbooks.Tests.ps1` covers scope/preview/scenario behavior;
`tests/OperationalWorkbookQueries.Tests.ps1` explicitly opts into read-only
execution of deterministic literal-table fixtures, not a live fault or ingestion.

`tests/Lifecycle.Tests.ps1` exercises waits, errors, config, mixed/native
classification, retained additive manifests, ShouldProcess previews, guest/job
failures and the JSON/exit-code contract without a cloud deployment.
Skin JSON uses PowerShell's native `-AsHashtable`; the redundant recursive
conversion helper is removed rather than adding another abstraction.
`.github/workflows/lint.yml` runs PSScriptAnalyzer, parsing/Pester, Bicep compile
and advisory documentation lint. Inspect the Markdown log rather than treating
the job's success alone as lint-clean. Pester is development-only.
