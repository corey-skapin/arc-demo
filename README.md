# Azure Arc Demo

> A scripted demo environment for showing Azure Arc + Azure Monitor to customers. Plan a preparation window; readiness, not elapsed time, determines when it is ready.

**Presenting an existing lab? Start with [the docs index](docs/README.md), then
the [first-time presenter guide](docs/runsheet.md).** You do not need to deploy,
induce a fault or read every operator reference to present the demo.

[CI workflow](.github/workflows/lint.yml)
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
| **Hibernated** | Retained-service costs remain; inspect network warnings | LAW, DCRs, workbooks, alerts, disks, Arc records | All demo infra-RG compute parked; NAT/PIP removed only when safe |
| **Removed** | Verify final charges | Shared/subscription services unless explicitly removed | Two demo RGs, named policies and budget |

The previous AUD 210 total was incorrect: its unverified line items sum to 358.
See [`docs/cost.md`](docs/cost.md), not those legacy numbers, before budgeting.

## Quick start

### Prerequisites

- Azure subscription where you have effective **Owner**, or **Contributor + User Access Administrator**, including inherited/group assignments
- PowerShell 7.4+
- Azure CLI 2.60+
- Bicep CLI (`az bicep install`)
- Permission to create service principals in the target tenant
- An email address for cost & alert notifications

For lab repeatability, use a clean/new subscription in the **same tenant** you will use for any later optional `sre-agent` lab. Pass tenant and subscription IDs at runtime; do not hard-code private subscription details in docs or scripts.

### Deploy

Copy a bundled synthetic skin to a private file outside git and use that
`<PRIVATE_SKIN_PATH>` consistently. Do not overwrite an existing lab's retained
runtime skin with the handoff example.

```powershell
git clone <ARC_REPOSITORY_URL> arc-demo
cd arc-demo

# Sign in to the target tenant
az login --tenant <TENANT_ID>
az account set --subscription <SUBSCRIPTION_ID>

# Check you've got what you need
.\scripts\Test-Prerequisites.ps1 -SubscriptionId <SUB> -TenantId <TENANT>

# Deploy default Act-1 Arc/Monitor estate. SQL Server/Arc SQL/BPA is skipped by default.
.\scripts\Deploy-ArcDemo.ps1 `
  -SubscriptionId <SUB> `
  -TenantId <TENANT> `
  -SkinPath <PRIVATE_SKIN_PATH>

# Example: add Azure-native VM + Container App alert scenario
.\scripts\Deploy-ArcDemo.ps1 `
  -SubscriptionId <SUB> `
  -TenantId <TENANT> `
  -SkinPath <PRIVATE_SKIN_PATH> `
  -DeployAzureVMs $true `
  -DeployContainerApps $true
```

When it finishes, open the workbook URL printed at the end, or open
**Monitor** > **Workbooks** and select the saved **Arc Demo - Estate Overview** (or skin
title), not a template. The [presenter guide](docs/runsheet.md) explains scope,
current navigation, expected data and fallback checks.

> **Optional SQL stance:** Installing SQL Server on an Azure VM is fine for workload simulation, but this Azure-VM-backed demo should not claim **SQL Server enabled by Azure Arc** validation. Keep SQL skipped by default until a SQL workload simulation is deliberately added. See [`docs/sql-arc-spike.md`](docs/sql-arc-spike.md).

### Use it

Follow [`docs/runsheet.md`](docs/runsheet.md): one practice pass followed by a
20-30 minute Arc/Monitor story, or a 12-15 minute core. The default presentation
is read-only. Optional live faults have separate approval/procedure; this repo
deploys email routing, not a Logic Apps/ITSM workflow.

### Sharing and runtime inputs

Tracked skins use fictitious organizations and a reserved example mailbox.
Replace repository URL placeholders with the handoff repositories, and supply
the operator-approved email and explicit subscription/tenant at runtime.
For an existing estate, keep its exact retained skin/fleet, targets, manifests
and evidence privately outside git; the sanitized default is not its runtime
configuration and must not silently replace it.

Public Azure role/schema IDs and required upstream workbook attribution remain.
Git history, commit authors, remotes and hosting metadata are not de-identified
by editing tracked files. For a source-only handoff, export the sanitized tracked
tree without `.git` and review the destination's metadata separately. History
has not been rewritten; never put credentials or private evidence in source.

### Hibernated / Active

```powershell
# After approval: park demo infra-RG compute; remove NAT/PIP only when safely exclusive
.\scripts\Hibernate-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath <PRIVATE_SKIN_PATH>

# Before the next demo; no automatic fault reset or credential rotation
.\scripts\Activate-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath <PRIVATE_SKIN_PATH>
.\scripts\Test-ArcDemoReadiness.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath <PRIVATE_SKIN_PATH> -OutputFormat Json -TimeoutSeconds 600
```

This is distinct from cleanup deletion: it preserves resource groups, Arc records,
workbooks, DCRs, alerts, disks, and Log Analytics so the demo can be reactivated.
Use `Remove-ArcDemo.ps1` only when you want to delete the estate permanently.
Every activation checks guest health, including already-running hosts on a
retry, without restarting already-correct services. Windows Arc AMA is checked
through its `MonAgentCore` process, not an assumed Windows service.
Host checks run concurrently. Windows AMA has a ten-minute startup budget;
timeout is recorded as pending, not repaired. Telemetry-only lag does not fail
activation, but the AI must poll readiness before presentation/SRE/incident offers.
Activation submits on-demand Azure Update Manager patch assessments only for
Arc hosts started/waking on that attempt unless skipped. Already-active retries
still verify guests but do not resubmit assessments. Use `-AssessPatches` for an
explicit all-host assessment retry. The job runs asynchronously, so open the
Update Manager blade later in the walkthrough or allow several minutes for the
portal data to refresh. Optional `-ResultPath` saves per-host outcomes in an
existing private directory outside git. Monitor Ready alone does not prove the
entire activation script completed.

Retain the confirmed runtime target, skin/fleet files and subscription deployment
history outside public source. Hibernation preserves identities, credentials and
fault settings; it deactivates Container App revisions rather than changing their
environment variables. If a companion SRE layer is attached, park that layer first
using its own maintained procedure, then park Arc to avoid investigations of
intentionally disconnected hosts. See [lifecycle.md](docs/lifecycle.md).

`-DesiredState Active` is the user-facing state name (`Ready` remains compatible).
Hibernate parks all compute in the explicit demo infra group even if manifests,
OS metadata or the skin drift. Strict ownership still gates VM startup/deletion.
Hibernated required checks cover deallocated/stopped compute and inactive app
revisions; NAT/PIP absence is a cost diagnostic. Foreign/shared networking is
left untouched with a warning, so exit 0 does not promise network cleanup.
Retained monitoring is not queried while parked. Unknown/denied compute
inspection still fails; it is never evidence of stopped compute. Removed readiness works after deployment
history disappears and verifies both groups plus named policies/budget absent;
retained tenant identities, shared/subscription services and soft-deleted vaults
are explicit exclusions, not a promise of a zero bill.

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

Customer-specific values belong in a **private copy** of
[`config\demo-skin.json`](config/demo-skin.json), outside git. Retarget the
demo name, prefix, region, recipient, workload toggles, workbook labels and tags
there; see [reskin-guide.md](docs/reskin-guide.md). Runtime arguments override
the skin; preserve an existing lab's effective inputs.

Deployment parameters (lifecycle scripts expose a smaller, documented subset):

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
| `-VmSize` | `Standard_B2as_v2` | Check regional restrictions/quota; listings and `--validate` do not guarantee capacity |
| `-OsDiskStorageAccountType` | `StandardSSD_LRS` | Fresh OS disks use SSD; select explicit `Standard_LRS` for a retained HDD lab. Existing-tier mismatch is refused, not converted. See [cost.md](docs/cost.md). |
| `-AdminEmail` | skin `notifications.email` | Email for budget + alert notifications |
| `-AutoShutdownTime` | `1900` | 24-hour HHMM in `AutoShutdownTimezone` |
| `-AutoShutdownTimezone` | `Cen. Australia Standard Time` | .NET timezone ID for shutdown |
| `-SkipSqlInstall` | *(compatibility)* | Deprecated compatibility switch; SQL is already skipped by default |

Example using only the skin for customer defaults:

```powershell
.\scripts\Deploy-ArcDemo.ps1 `
  -SubscriptionId <SUB> `
  -TenantId <TENANT> `
  -SkinPath <PRIVATE_SKIN_PATH>
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

Lead with the workbook, then telemetry/diagnosis, alert routing and the Arc
identity. Add rehearsed patch/security/governance beats if populated.
[The runsheet](docs/runsheet.md) owns the sequence, current source-grounded
navigation and honest missing-data fallbacks; a TLS tag is not a TLS policy test.

Infrastructure/monitoring readiness is not endpoint-protection validation. The
inspected Linux sensors reported healthy/licensed **in passive mode**, with
real-time protection disabled; extension-reported event-provider issues also
need separate interpretation. Do not promise active antivirus or fully validated
EDR from a passing readiness snapshot. See [support boundaries](docs/lifecycle.md).

## For AI coding agents

If you're using GitHub Copilot CLI, Claude Code, Cursor, Windsurf, Aider, or any other AI coding assistant, **point it at [`AGENTS.md`](AGENTS.md) first**. It contains the constraints, gotchas, and conventions the AI needs to be helpful here.

## Documentation map

[**docs/README.md**](docs/README.md) indexes **every document**, its audience,
canonical/reference/optional status and the minimal ordered presenter path.
Use it instead of treating all files as required reading.

- Present: [runsheet.md](docs/runsheet.md).
- Operate: [runbook.md](docs/runbook.md) and [lifecycle.md](docs/lifecycle.md).
- Develop: [AGENTS.md](AGENTS.md), [CONTRIBUTING.md](CONTRIBUTING.md) and
  [module-map.md](docs/module-map.md).

## Inspiration & credits

- Demo flow modelled on **[Nic Seilaz's](https://github.com/nseilaz)** Arc + Azure Monitor demo. The persona-first structure (exec → security → ops) and the focus on workbooks-as-story were his ideas.
- **Workbook library** in `workbooks/nseilaz/` is a vendored snapshot from [github.com/nseilaz/AzureArc_Workbooks](https://github.com/nseilaz/AzureArc_Workbooks) (MIT). Run `Deploy-ArcDemo.ps1` and they'll land in your demo workspace alongside our custom one-pager.

## License

MIT — see [`LICENSE`](LICENSE).
