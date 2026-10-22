# Arc demo module map

This is the current maintained surface map; line numbers are intentionally omitted
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
| `bicep/modules/workspace.bicep` | Log Analytics and VMInsights/ChangeTracking solutions |
| `bicep/modules/dcrs.bicep` | Deterministic DCR IDs; imperative post-table-readiness creation is in the deploy wrapper |
| `bicep/modules/alerts.bicep` | Action Group and missing-Heartbeat alert |
| `bicep/modules/defender.bicep` | Subscription Defender for Servers P2 |
| `bicep/modules/policy.bicep` | Named MCSB/NIST assignments |
| `bicep/modules/budget.bicep` | Named budget filtered to demo RGs, notification thresholds |

Fresh deployment creates NAT/PIP; hibernation deletes them and activation
recreates them. A routine Bicep rerun preserves an existing gateway. The backing compute is an Azure-hosted simulation;
the customer-facing Arc records and observability plane are in the other group.

## Operations

| Entry point | Responsibility |
|---|---|
| `scripts/Test-Prerequisites.ps1` | Read-only tools/context/effective permissions/baseline provider checks |
| `scripts/Deploy-ArcDemo.ps1` | Selected-provider and SKU/quota checks; Bicep preview/create; preserve credentials/faults; NAT; Arc onboarding; checked extension jobs; DCRAs; workbook upsert; required infrastructure/monitor readiness |
| `scripts/Activate-ArcDemo.ps1` | Explicit target, retained manifests, restore NAT/start workloads/reconnect where needed, optional asynchronous patch submission, readiness |
| `scripts/Hibernate-ArcDemo.ps1` | Best-effort all-compute parking inside the explicit infra RG despite manifest/skin drift; safe NAT cleanup afterward; retains faults/data |
| `scripts/Remove-ArcDemo.ps1` | Named policy/budget and group deletion with bounded completion; optional identity/Defender changes |
| `scripts/Test-ArcDemoReadiness.ps1` | Read-only JSON v1/Table; Active (Ready alias), compute-only Hibernated with network cost diagnostics, Removed; bounded retries, exit 0/1/2 |
| `scripts/lib/Common.psm1` | Skin/fleet validation, checked CLI/REST with subscription pinning and tenant-only directory guards, retained inventory, bounded waits/jobs, `@file` guest-script transport/markers, capacity/quota, readiness checks |
| `scripts/Invoke-SqlWorkloadOnArc.ps1` | Separate SQL-shaped guest signal simulator; not SQL Server enabled by Azure Arc validation |

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

`tests/Lifecycle.Tests.ps1` exercises waits, errors, config, mixed/native
classification, retained additive manifests, ShouldProcess previews, guest/job
failures and the JSON/exit-code contract without a cloud deployment.
Skin JSON uses PowerShell's native `-AsHashtable`; the redundant recursive
conversion helper is removed rather than adding another abstraction.
`.github/workflows/lint.yml` runs PSScriptAnalyzer, parsing/Pester, Bicep compile
and advisory documentation lint. Inspect the Markdown log rather than treating
the job's success alone as lint-clean. Pester is development-only.
