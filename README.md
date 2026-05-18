# Azure Arc Demo

> A scripted, repeatable demo environment for showing Azure Arc + Azure Monitor to customers. Stand it up in ~30 min, hibernate it between demos for ~AUD 35/mo, wake it up in ~5 min.

[![Lint](https://github.com/corey-skapin/arc-demo/actions/workflows/lint.yml/badge.svg)](https://github.com/corey-skapin/arc-demo/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## What you get

8 Azure VMs registered as Arc-enabled servers (with `MSFT_ARC_TEST=true` — fully supported for demo/test scenarios), wired into a Log Analytics workspace with Defender for Servers Plan 2, VM Insights, Change Tracking, MCSB + NIST policy initiatives, and a custom workbook tuned for the persona-first demo flow described in [`docs/runsheet.md`](docs/runsheet.md).

- 5 × Windows Server 2022 (2 of which run **SQL Server 2022 Developer**, Arc-enabled with BPA)
- 3 × Ubuntu 22.04 LTS
- VM SKU: `Standard_B2as_v2` (2 vCPU / 8 GiB AMD burstable, ~AUD 50/mo each)
- Defender for Servers **Plan 2** at subscription scope
- DevTest-Labs auto-shutdown at 19:00 local time
- Custom workbook with 8 tiles modelled on the original demo flow

See [`docs/architecture.md`](docs/architecture.md) for the full topology.

## Cost states

| State | ~AUD/month | What stays | What goes |
|---|---|---|---|
| **Active** | ~210 | Everything | Nothing (VMs auto-shutdown overnight) |
| **Hibernated** | ~35 | LAW, DCRs, workbook, alerts, disks, Arc records | NAT GW, public IP, VM compute, Defender per-host charges |
| **Removed** | 0 | Nothing | Everything |

Full breakdown: [`docs/cost.md`](docs/cost.md).

## Quick start

### Prerequisites

- Azure subscription where you have **Owner** role
- PowerShell 7.4+
- Azure CLI 2.60+
- Bicep CLI (`az bicep install`)
- Permission to create service principals in the target tenant
- An email address for cost & alert notifications

### Deploy

```powershell
git clone https://github.com/corey-skapin/arc-demo C:\src\arc-demo
cd C:\src\arc-demo

# Sign in to the target tenant
az login --tenant <TENANT_ID>
az account set --subscription <SUBSCRIPTION_ID>

# Check you've got what you need
.\scripts\Test-Prerequisites.ps1 -SubscriptionId <SUB> -TenantId <TENANT>

# Deploy (~25-30 min end-to-end)
.\scripts\Deploy-ArcDemo.ps1 `
  -SubscriptionId <SUB> `
  -TenantId <TENANT> `
  -AdminEmail you@contoso.com
```

When it finishes, open the workbook URL printed at the end (or navigate to **Azure Arc → Workbooks → "Arc Demo — Estate Overview"** in the portal).

### Use it

Follow [`docs/runsheet.md`](docs/runsheet.md) — a 15-25 min persona-ordered walkthrough that mirrors the demo flow this repo was built to replicate.

### Hibernate / activate

```powershell
# After a demo — drops to ~AUD 35/mo
.\scripts\Hibernate-ArcDemo.ps1

# Before the next demo — back to demo-ready in ~5-8 min
.\scripts\Activate-ArcDemo.ps1
```

### Remove permanently

```powershell
.\scripts\Remove-ArcDemo.ps1 -WhatIf   # preview
.\scripts\Remove-ArcDemo.ps1
```

## Customisation

All scripts accept parameters. The most useful:

| Parameter | Default | Purpose |
|---|---|---|
| `-Location` | `australiaeast` | Azure region for all resources |
| `-NamePrefix` | `arc-demo` | Used for RG / resource names (e.g. `rg-arc-demo`, `kv-arc-demo-xxxx`) |
| `-WindowsVmCount` | `5` | Number of Windows VMs (2 reserved for SQL) |
| `-LinuxVmCount` | `3` | Number of Linux VMs |
| `-VmSize` | `Standard_B2as_v2` | VM SKU. Probe with `--validate` before changing |
| `-AdminEmail` | *(required)* | Email for budget + alert notifications |
| `-AutoShutdownTime` | `1900` | 24-hour HHMM in `AutoShutdownTimezone` |
| `-AutoShutdownTimezone` | `Cen. Australia Standard Time` | .NET timezone ID for shutdown |
| `-SkipSqlInstall` | `$false` | Set to skip SQL installation (saves ~20 min) |

## For AI coding agents

If you're using GitHub Copilot CLI, Claude Code, Cursor, Windsurf, Aider, or any other AI coding assistant, **point it at [`AGENTS.md`](AGENTS.md) first**. It contains the constraints, gotchas, and conventions the AI needs to be helpful here.

## Documentation map

| File | Purpose |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | What gets deployed and how it's wired together |
| [`docs/runbook.md`](docs/runbook.md) | The original step-by-step build runbook |
| [`docs/runsheet.md`](docs/runsheet.md) | Live demo walkthrough — what to click and what to say |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | Every failure mode I've hit and how to fix it |
| [`docs/cost.md`](docs/cost.md) | Detailed cost breakdown by state |
| [`AGENTS.md`](AGENTS.md) | Operating manual for AI coding assistants |

## Inspiration & credits

Demo flow modelled on **Nic Seilaz's** Arc + Azure Monitor demo. The persona-first structure (exec → security → ops) and the focus on workbooks-as-story were his ideas; this repo is the scripted version.

## License

MIT — see [`LICENSE`](LICENSE).
