# Azure Arc Demo

> A scripted demo environment for showing Azure Arc + Azure Monitor to customers. Plan a preparation window; readiness, not elapsed time, determines when it is ready.

[![Lint](https://github.com/corey-skapin/arc-demo/actions/workflows/lint.yml/badge.svg)](https://github.com/corey-skapin/arc-demo/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## What you get

A **standalone Azure Arc + Azure Monitor lab**. It does **not** require Azure SRE Agent or any later repo; the optional `sre-agent` repo can be layered on afterwards against the alerts this repo emits.

Default deployment:

- 8 config-driven Azure VMs registered as Arc-enabled servers (with `MSFT_ARC_TEST=true` for demo/test simulation, not production or blanket feature-support validation)
- 5 × Windows Server across WS2016/WS2019/WS2022 by default, including 2 SQL-capable Windows hosts (`win-sql-01/02`) that remain plain Windows VMs unless the optional advanced SQL path is explicitly enabled
- 3 × Ubuntu 22.04 LTS
- Log Analytics workspace, DCRs, Defender for Servers Plan 2, VM Insights, Change Tracking, Azure Update Manager periodic assessment, MCSB + NIST policy initiatives, heartbeat alert, Action Group, and a custom workbook tuned for [`docs/runsheet.md`](docs/runsheet.md)

Optional workloads, independently toggleable in any combination:

- Azure-native Windows VM (`-DeployAzureVMs $true`) with AMA + DCR associations to the shared workspace
- Container App (`-DeployContainerApps $true`) with a `SIMULATE_CRASH` fault toggle and `RestartCount` alert
- AKS (`-DeployAks $true`) with Container Insights, a sample crash-loop workload, and pod restart alert
- LOB Arc bridge sample source under `samples/lob-arc-app` for the companion SRE Agent hybrid diagnostics scenario
- SQL-shaped workload simulator under `samples/sql-workload` for DBA-relevant Arc/Monitor signals without claiming Arc-enabled SQL Server

Legacy Windows tiers such as WS2012R2/WS2008R2 are represented as Arc-control-plane-only entries: inventory/tags, ESU discussion, Update Manager/Defender/Machine Configuration surfaces where available, but no AMA/VM Insights/Change Tracking payloads on unsupported OS versions. See [`docs/legacy-os-fleet.md`](docs/legacy-os-fleet.md).

See [`docs/architecture.md`](docs/architecture.md) for the full topology.

## Cost states

Default Act-1 deployment costs are shown below. Optional Azure VM, Container App, and AKS workloads add their own incremental cost.

| State | Cost stance | What stays | What goes |
|---|---|---|---|
| **Active** | Reprice selected workloads | Everything | Nothing (VM auto-shutdown is not whole-lab hibernation) |
| **Hibernated** | Retained-service costs remain | LAW, DCRs, workbooks, alerts, disks, Arc records | Demo NAT/PIP, VM compute; optional AKS stopped and Container App revisions inactive |
| **Removed** | Verify final charges | Shared/subscription services unless explicitly removed | Two demo RGs, named policies and budget |

The previous AUD 210 total was incorrect: its unverified line items sum to 358.
See [`docs/cost.md`](docs/cost.md), not those legacy numbers, before budgeting.

## Quick start

### Prerequisites

- Azure subscription where you have **Owner** role
- PowerShell 7.4+
- Azure CLI 2.60+
- Bicep CLI (`az bicep install`)
- Permission to create service principals in the target tenant
- An email address for cost & alert notifications

For lab repeatability, use a clean/new subscription in the **same tenant** you will use for any later optional `sre-agent` lab. Pass tenant and subscription IDs at runtime; do not hard-code private subscription details in docs or scripts.

### Deploy

```powershell
git clone https://github.com/corey-skapin/arc-demo C:\src\arc-demo
cd C:\src\arc-demo

# Sign in to the target tenant
az login --tenant <TENANT_ID>
az account set --subscription <SUBSCRIPTION_ID>

# Check you've got what you need
.\scripts\Test-Prerequisites.ps1 -SubscriptionId <SUB> -TenantId <TENANT>

# Deploy default Act-1 Arc/Monitor estate. SQL Server/Arc SQL/BPA is skipped by default.
.\scripts\Deploy-ArcDemo.ps1 `
  -SubscriptionId <SUB> `
  -TenantId <TENANT> `
  -SkinPath .\config\demo-skin.json

# Example: add Azure-native VM + Container App alert scenario
.\scripts\Deploy-ArcDemo.ps1 `
  -SubscriptionId <SUB> `
  -TenantId <TENANT> `
  -SkinPath .\config\demo-skin.json `
  -DeployAzureVMs $true `
  -DeployContainerApps $true
```

When it finishes, open the workbook URL printed at the end, or search for
**Workbooks** in the Azure portal and select **Arc Demo - Estate Overview** in
`rg-arc-demo`.

> **Optional SQL stance:** Installing SQL Server on an Azure VM is fine for workload simulation, but this Azure-VM-backed demo should not claim **SQL Server enabled by Azure Arc** validation. Keep SQL skipped by default until a SQL workload simulation is deliberately added. See [`docs/sql-arc-spike.md`](docs/sql-arc-spike.md).

### Use it

Follow [`docs/runsheet.md`](docs/runsheet.md) — a 20-30 min Act-1 Arc/Monitor walkthrough with optional Azure-native workload beats.

### Off state / activate

```powershell
# After explicit operator approval: deallocates VMs, stops AKS, deactivates Container Apps, removes NAT
.\scripts\Hibernate-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath .\config\demo-skin.json

# Before the next demo; no automatic fault reset or credential rotation
.\scripts\Activate-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath .\config\demo-skin.json
.\scripts\Test-ArcDemoReadiness.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -OutputFormat Json
```

This is distinct from cleanup deletion: it preserves resource groups, Arc records,
workbooks, DCRs, alerts, disks, and Log Analytics so the demo can be reactivated.
Use `Remove-ArcDemo.ps1` only when you want to delete the estate permanently.
Activation also starts on-demand Azure Update Manager patch assessments after
the Arc machines reconnect. The assessment job runs asynchronously, so open the
Update Manager blade later in the walkthrough or allow several minutes for the
portal data to refresh.

### Remove permanently

```powershell
.\scripts\Remove-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -WhatIf
.\scripts\Remove-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT>
```

## Customisation

See [`docs/lifecycle.md`](docs/lifecycle.md) for the readiness JSON/exit-code
contract, retained manifests, explicit targeting, retry/credential behavior,
optional-workload parking, cleanup scope and validation boundaries. Removal
preserves subscription Defender by default; identity deletion is separately opt-in.

Customer-specific values live in [`config\demo-skin.json`](config/demo-skin.json). Change that file to retarget the demo name, resource prefix, region, notification email, workload toggles, workbook labels, and tags; see [`docs/reskin-guide.md`](docs/reskin-guide.md) for the swap-list and dummy-customer example. Runtime command-line parameters still override the skin when you need a one-off change.

All scripts accept parameters. The most useful:

| Parameter | Default | Purpose |
|---|---|---|
| `-SkinPath` | `config\demo-skin.json` | Variables file for customer skin defaults |
| `-Location` | `australiaeast` | Azure region for all resources |
| `-NamePrefix` | `arc-demo` | Used for RG / resource names (e.g. `rg-arc-demo`, `kv-arc-demo-xxxx`) |
| `-DeployArcOnPrem` | `$true` | Deploy the on-prem-simulated Arc VM workload |
| `-DeployAzureVMs` | `$false` | Deploy a monitored Azure-native Windows VM workload (not Arc-enabled) |
| `-DeployContainerApps` | `$false` | Deploy a tiny Azure Container App with a `SIMULATE_CRASH` fault toggle and RestartCount alert |
| `-DeployAks` | `$false` | Deploy AKS with Container Insights, crash-loop sample workload, and pod-restart alert |
| `-OnPremFleetPath` | *(empty)* | Optional JSON fleet array. Omit to use the default WS2016/2019/2022 + Ubuntu mix |
| `-InstallSql` | `$false` | Experimental legacy path. Do not use for Arc SQL claims. Future SQL work should split workload simulation from true Arc SQL validation; see `docs/sql-arc-spike.md` |
| `-WindowsVmCount` | `5` | Deprecated compatibility generator for an all-WS2022 count-based fleet |
| `-LinuxVmCount` | `3` | Deprecated compatibility generator for an Ubuntu count-based fleet |
| `-VmSize` | `Standard_B2as_v2` | VM SKU. Probe with `--validate` before changing |
| `-AdminEmail` | skin `notifications.email` | Email for budget + alert notifications |
| `-AutoShutdownTime` | `1900` | 24-hour HHMM in `AutoShutdownTimezone` |
| `-AutoShutdownTimezone` | `Cen. Australia Standard Time` | .NET timezone ID for shutdown |
| `-SkipSqlInstall` | *(compatibility)* | Deprecated compatibility switch; SQL is already skipped by default |

Example using only the skin for customer defaults:

```powershell
.\scripts\Deploy-ArcDemo.ps1 `
  -SubscriptionId <SUB> `
  -TenantId <TENANT> `
  -SkinPath .\config\demo-skin.json
```

### Common workload combinations

| Demo goal | Switches |
|---|---|
| Act-1 Arc/Monitor only (default) | *(none)* |
| Arc/Monitor + Azure-native VM comparison | `-DeployAzureVMs $true` |
| Arc/Monitor + Container App fault alert | `-DeployContainerApps $true` |
| Arc/Monitor + AKS crash-loop alert | `-DeployAks $true` |
| All current workloads | `-DeployAzureVMs $true -DeployContainerApps $true -DeployAks $true` |
| Azure-native scenarios without Arc backing VMs | `-DeployArcOnPrem $false -DeployAzureVMs $true -DeployContainerApps $true` |

### OS-tier demo coverage

| Tier | Demo coverage |
|---|---|
| WS2016+ | Full Monitor path: AMA, core DCR, VM Insights, Change Tracking, Defender, Update Manager/Machine Configuration surfaces, workbook/alert data |
| Ubuntu 22.04 | AMA + core DCR + Change Tracking; VM Insights map is intentionally off until Dependency Agent support is validated |
| WS2008/WS2012-era | Arc-control-plane-only: inventory/resource graph, tags, ESU eligibility discussion, Update Manager/Defender/Machine Configuration surfaces where available; no AMA/VM Insights/Change Tracking |

The live Arc cook's tour is: inventory, Machine Configuration/TLS 1.2 policy posture, Update Manager, Defender, and ESU. See [`docs/runsheet.md`](docs/runsheet.md) for click-path and talk track.

## For AI coding agents

If you're using GitHub Copilot CLI, Claude Code, Cursor, Windsurf, Aider, or any other AI coding assistant, **point it at [`AGENTS.md`](AGENTS.md) first**. It contains the constraints, gotchas, and conventions the AI needs to be helpful here.

## Documentation map

| File | Purpose |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | What gets deployed and how it's wired together |
| [`docs/legacy-os-fleet.md`](docs/legacy-os-fleet.md) | Fleet schema, legacy OS image approach, and Monitor gating rules |
| [`docs/container-app-fault.md`](docs/container-app-fault.md) | Optional Container App fault/repair commands and alert mechanism |
| [`docs/aks-break-scenario.md`](docs/aks-break-scenario.md) | Optional AKS crash-loop/repair commands and alert mechanism |
| [`docs/runbook.md`](docs/runbook.md) | Historical deep build notes; use README + `docs/runsheet.md` for the current handoff path |
| [`docs/runsheet.md`](docs/runsheet.md) | Live demo walkthrough — what to click and what to say |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | Every failure mode I've hit and how to fix it |
| [`docs/cost.md`](docs/cost.md) | Detailed cost breakdown by state |
| [`docs/reskin-guide.md`](docs/reskin-guide.md) | Skin variables schema, swap-list, and retargeting steps |
| [`docs/ai-deploy-handbook.md`](docs/ai-deploy-handbook.md) | Prompt and checklist for AI-assisted deployment by another SE |
| [`docs/sql-arc-spike.md`](docs/sql-arc-spike.md) | Decision record for SQL Server / Arc SQL support, blockers, and supported alternatives |
| [`docs/sql-workload-simulation.md`](docs/sql-workload-simulation.md) | Optional SQL-shaped workload signal on an Arc-enabled Windows server |
| [`AGENTS.md`](AGENTS.md) | Operating manual for AI coding assistants |
| [`samples/lob-arc-app`](samples/lob-arc-app) | Public LOB app source used by the SRE Agent T11 code-context demo |
| [`samples/sql-workload`](samples/sql-workload) | SQL-shaped Application Event simulator for the optional DBA beat |

## Inspiration & credits

- Demo flow modelled on **[Nic Seilaz's](https://github.com/nseilaz)** Arc + Azure Monitor demo. The persona-first structure (exec → security → ops) and the focus on workbooks-as-story were his ideas.
- **Workbook library** in `workbooks/nseilaz/` is a vendored snapshot from [github.com/nseilaz/AzureArc_Workbooks](https://github.com/nseilaz/AzureArc_Workbooks) (MIT). Run `Deploy-ArcDemo.ps1` and they'll land in your demo workspace alongside our custom one-pager.

## License

MIT — see [`LICENSE`](LICENSE).
