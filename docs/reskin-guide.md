# Reskin guide — Arc/Monitor foundation

The repo has a stable **spine** (Bicep, DCRs, workbooks, alerts, scripts) and a customer **skin** in `config\demo-skin.json`. Defaults reproduce the DTF baseline without private subscription, tenant, or mailbox details; change `notifications.email` before a live deploy.

## Variable surface

| Path | Purpose | Default |
|---|---|---|
| `customer.*` | Customer name, short name, and scenario label for docs/talk track. | SA DTF / DTF / Infrastructure Modernisation Program |
| `azure.namePrefix` | Resource name prefix: `rg-<prefix>`, `law-<prefix>`, alerts, NAT GW, optional workloads. | `arc-demo` |
| `azure.location` | Azure region. | `australiaeast` |
| `notifications.email` | Budget and Action Group email receiver. | `you@contoso.com` placeholder |
| `workloads.*` | Act-1 and optional workload toggles. | Arc on-prem simulation on; optional Azure VM/Container App/AKS off |
| `compute.vmSize` | VM SKU for Arc-simulated and optional native VMs. | `Standard_B2as_v2` |
| `operations.*` | Auto-shutdown schedule. | 19:00 Cen. Australia Standard Time |
| `cost.monthlyBudgetAmount` | Subscription budget threshold. | `200` |
| `labels.*` | Demo title, workbook display name, opening/closing talk-track labels. | Arc Demo labels |
| `tags.*` | Common Azure tags. | demo tags |

## Swap list

Change per customer:
- `customer`, `azure.namePrefix`, `notifications.email`, `labels`, and `tags.purpose`.
- `workloads` to match the story: core Arc only, native comparison, Container App fault, AKS fault, or all.
- `workloads.onPremFleetPath` for a custom OS mix.

Keep constant unless the lab requirement changes:
- Bicep modules, DCR streams, workbook templates, alert mechanics, Defender/Policy choices, hibernate/activate flow.
- The repo separation: `arc-demo` remains standalone and does not require `sre-agent`.

## Retarget steps

1. Copy `config\demo-skin.json` or start from `config\dummy-customer.demo-skin.json`.
2. Set `azure.namePrefix` to a short lowercase prefix that is valid in Azure resource names.
3. Set `notifications.email` to the demo operator or customer-approved distribution list.
4. Choose workload toggles.
5. Run scripts without repeating those variables:
   ```powershell
   .\scripts\Deploy-ArcDemo.ps1 `
     -SubscriptionId <SUBSCRIPTION_ID> `
     -TenantId <TENANT_ID> `
     -SkinPath .\config\demo-skin.json
   ```
6. Use the same skin for lifecycle commands:
   ```powershell
   .\scripts\Activate-ArcDemo.ps1 -SkinPath .\config\demo-skin.json
   .\scripts\Hibernate-ArcDemo.ps1 -SkinPath .\config\demo-skin.json
   .\scripts\Remove-ArcDemo.ps1 -SkinPath .\config\demo-skin.json -WhatIf
   ```

## Off state vs cleanup

`Hibernate-ArcDemo.ps1` is the weekend/off state. It deallocates VMs, deletes the
NAT Gateway and public IP, resets any optional Container App fault, and scales
Container Apps to zero-min replicas. It keeps the estate intact: resource groups,
Arc records, workbooks, DCRs, alerts, disks, and Log Analytics remain.

`Remove-ArcDemo.ps1` is cleanup deletion. Use it only when the demo should be
permanently removed.

## Examples

DTF/default: use `config\demo-skin.json` as-is, replacing only `notifications.email` and runtime subscription/tenant.

Dummy customer: compare with `config\dummy-customer.demo-skin.json`; it changes the prefix to `contoso-arc`, workbook title to `Contoso — Hybrid Estate Overview`, turns on Azure VM + Container App, and skips SQL install.

## Remaining constants

The following strings intentionally remain in code/docs because they identify the reusable spine, not a customer skin: repo names (`arc-demo`, `sre-agent`), feature flags (`SIMULATE_CRASH`, `CRASH_LOOP`), built-in workbook names from the vendored Nic Seilaz library, sample host names (`win-app-01`), and sample commands in historical runbooks. Live scripts now read customer-facing deploy defaults from the skin file.
