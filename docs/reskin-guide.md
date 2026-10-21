# Reskin guide — Arc/Monitor foundation

The repo has a stable **spine** (Bicep, DCRs, workbooks, alerts, scripts) and a customer **skin** in `config\demo-skin.json`. Bundled skins are fictitious handoff examples, not a live customer's configuration; change `notifications.email` before a live deploy.

## Variable surface

| Path | Purpose | Default |
|---|---|---|
| `customer.*` | Fictitious organization name, short name, and scenario label. | Example Organization / DEMO / Hybrid Operations Demo |
| `azure.namePrefix` | Resource name prefix: `rg-<prefix>`, `law-<prefix>`, alerts, NAT GW, optional workloads. | `arc-demo` |
| `azure.location` | Azure region. | `australiaeast` |
| `notifications.email` | Budget and Action Group email receiver. | `operator@example.com` placeholder, rejected until replaced |
| `workloads.*` | Act-1 and optional workload toggles. | Arc on-prem simulation on; optional Azure VM/Container App/AKS/SQL off |
| `compute.vmSize` | VM SKU for Arc-simulated and optional native VMs. | `Standard_B2as_v2` |
| `compute.osDiskStorageAccountType` | OS disk tier for simulated/native VMs; wrapper rejects existing-tier mismatches rather than converting disks. | `StandardSSD_LRS` for new OS disks; explicit `Standard_LRS` for retained HDD labs only |
| `operations.*` | Auto-shutdown schedule. | 19:00 Cen. Australia Standard Time |
| `cost.monthlyBudgetAmount` | Subscription budget threshold. | `200` |
| `labels.*` | Demo title, workbook display name, opening/closing talk-track labels. | Arc Demo labels |
| `tags.*` | Common Azure tags. | demo tags |

## Swap list

Change per customer:

- `customer`, `azure.namePrefix`, `notifications.email`, `labels`, and `tags.purpose`.
- `workloads` to match the story: core Arc only, native comparison, Container App fault, AKS fault, or all implemented workloads. Validate the chosen estate separately; flags are not live validation. Leave `workloads.installSql` as `false` unless you intentionally want the experimental SQL branch.
- `workloads.onPremFleetPath` for a custom OS mix.
- Match `compute.osDiskStorageAccountType` to the existing OS disks for a
  retained lab. New labs should keep SSD: HDD OS disks retire on 8 September
  2028. Tier changes are separately approved maintenance, not reskinning.

Keep constant unless the lab requirement changes:

- Bicep modules, DCR streams, workbook templates, alert mechanics, Defender/Policy choices, hibernate/activate flow.
- The repo separation: `arc-demo` remains standalone and does not require `sre-agent`.

## Retarget steps

1. Copy `config\demo-skin.json` or `config\dummy-customer.demo-skin.json` to a private runtime file outside git.
2. Set `azure.namePrefix` to 3-20 lowercase letters/digits/hyphens, starting with a letter and ending with a letter/digit. Workload toggles must be JSON booleans, not strings. Missing or malformed skins fail explicitly.
3. Set `notifications.email` to the demo operator or customer-approved distribution list.
4. Choose workload toggles.
5. Run scripts without repeating those variables:

   ```powershell
   .\scripts\Deploy-ArcDemo.ps1 `
     -SubscriptionId <SUBSCRIPTION_ID> `
     -TenantId <TENANT_ID> `
     -SkinPath <PRIVATE_SKIN_PATH>
   ```

6. Use the same skin for lifecycle commands:

   ```powershell
   .\scripts\Activate-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath <PRIVATE_SKIN_PATH>
   .\scripts\Test-ArcDemoReadiness.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath <PRIVATE_SKIN_PATH> -OutputFormat Json
   .\scripts\Hibernate-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath <PRIVATE_SKIN_PATH> -WhatIf
   .\scripts\Remove-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath <PRIVATE_SKIN_PATH> -WhatIf
   ```

## Off state vs cleanup

`Hibernate-ArcDemo.ps1` is the weekend/off state. It deallocates VMs, deletes the
NAT Gateway and public IP, stops optional AKS, and deactivates optional Container
App revisions. Fault flags are preserved, not reset. It keeps the estate intact: resource groups,
Arc records, workbooks, DCRs, alerts, disks, and Log Analytics remain.

`Remove-ArcDemo.ps1` is cleanup deletion. Use it only when the demo should be
permanently removed.

Both operations require explicit operator approval. Removal preserves shared
subscription Defender by default. See [lifecycle.md](lifecycle.md) for exact
scope, retained deployment manifests, optional-workload costs and the readiness
JSON/exit-code contract. Changing skin toggles alone does not delete previously
deployed workloads; lifecycle still accounts for retained manifests.
Keep the chosen runtime target, skin/fleet files and deployment history in a
private operator handoff for reactivation; do not copy live IDs/secrets into the
customer skin. Park an attached SRE layer first through its own procedure.

## Examples

Generic default: copy `config\demo-skin.json`, replacing `notifications.email` and supplying the runtime subscription/tenant. Keep real customer names, recipients and resource targets outside tracked source.

Fictitious alternative: `config\dummy-customer.demo-skin.json` changes the prefix to `example-arc`, workbook title to `Example — Hybrid Estate Overview`, turns on Azure VM + Container App, and leaves the optional advanced SQL branch disabled. Replace its example mailbox too.

## Remaining constants

The following strings intentionally remain in code/docs because they identify the reusable spine, not a customer skin: repo names (`arc-demo`, `sre-agent`), feature flags (`SIMULATE_CRASH`, `CRASH_LOOP`), built-in workbook names from the vendored Nic Seilaz library and sample host names (`win-app-01`). Substitute the chosen names in examples; maintained lifecycle scripts use retained IDs and customer-facing defaults from the skin.
