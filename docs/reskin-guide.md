# Reskin guide — Arc/Monitor foundation

The repo has a stable **spine** (Bicep, DCRs, workbooks, alerts, scripts) and a customer **skin** in `config\demo-skin.json`. Bundled skins are fictitious examples, not a live customer's configuration; change `notifications.email` before a live deploy.

## Variable surface

| Path | Purpose | Default |
|---|---|---|
| `customer.*` | Fictitious organization name, short name, and scenario label. | Example Organization / DEMO / Hybrid Operations Demo |
| `azure.namePrefix` | Resource name prefix: `rg-<prefix>`, `law-<prefix>`, alerts, NAT GW, optional workloads. | `arc-demo` |
| `azure.location` | Azure region. | `australiaeast` |
| `notifications.email` | Budget and Action Group email receiver. | `operator@example.com` placeholder, rejected until replaced |
| `workloads.*` | Act-1 and optional workload toggles. | Arc on-prem simulation on; optional Azure VM/Container App/AKS/SQL off |
| `nestedSqlGuest.*` | One optional nested Windows/SQL guest: enabled, parent VM name, Hyper-V guest name and Arc name; used by Activate/Hibernate/Remove. Deploy also declares the parent from it: optional `parentVmSize`, `parentDataDiskGb`, `parentDataDiskStorageAccountType` override the defaults below. | Disabled; use the [nested SQL runbook](nested-sql-demo.md) to configure a private skin. Parent defaults: `Standard_D4s_v5`, 128 GiB `StandardSSD_LRS` data disk |
| `compute.vmSize` | VM SKU for Arc-simulated and optional native VMs. | `Standard_B2as_v2` |
| `compute.osDiskStorageAccountType` | OS disk tier for simulated/native VMs; wrapper rejects existing-tier mismatches rather than converting disks. | `StandardSSD_LRS` for new OS disks; explicit `Standard_LRS` for a lab whose disks are HDD (retained, or converted by a tenant automation while parked) |
| `operations.*` | Auto-shutdown schedule (`autoShutdownTime` as `HHmm`, `autoShutdownTimezone`). Deploy owns it and sets it again on every run, so set the time you want here before the Deploy; a hand-changed time is reverted, and Deploy says so before it submits. | 19:00 Cen. Australia Standard Time |
| `cost.monthlyBudgetAmount` | Subscription budget threshold. | `200` |
| `labels.*` | Demo title, workbook display name, opening/closing talk-track labels. | Arc Demo labels |
| `tags.*` | Common Azure tags. | demo tags |

## Swap list

Change per customer:

- `customer`, `azure.namePrefix`, `azure.location` (the region), `notifications.email`, `operations.autoShutdownTime` and `operations.autoShutdownTimezone` (the shutdown time and its Windows time zone name), `labels`, and `tags.purpose`. The shipped defaults are the author's (`australiaeast`, 19:00 Cen. Australia Standard Time, AUD figures in [cost.md](cost.md), `Standard_B2as_v2`), so change them to yours.
- The SRE half works only in an [SRE Agent supported region](https://learn.microsoft.com/azure/sre-agent/supported-regions) (Australia East is on it). The companion repo's README lists SRE registration and region availability as separate prerequisites. Its own skin, `sre-skin.json` in your private folder (a copy of the clone's `config\demo-skin.json`), must carry the same `azure.namePrefix` and `azure.location` as the Arc skin, and `labels.agentName` should follow the prefix (`sre-<prefix>`). The [setup block](private-config.md#set-up-the-whole-demo) writes both skins together.
- `workloads` to match the story: core Arc only, native comparison, Container App fault, AKS fault, or all implemented workloads. Validate the chosen estate separately; flags are not live validation. [Real SQL preparation](sql-engine-workload.md) is a separate operation, not a deployment flag.
- `workloads.onPremFleetPath` for a custom OS mix.
- Match `compute.osDiskStorageAccountType` to the existing OS disks for a
  retained lab, and `nestedSqlGuest.parentDataDiskStorageAccountType` to the
  nested parent's data disk. New labs should keep SSD: HDD OS disks retire on
  8 September 2028. Tier changes are separate maintenance, not
  reskinning; a tier that changed by itself is declared as it is
  ([troubleshooting](troubleshooting.md#the-os-disk-tier-changed-by-itself)).

Keep constant unless the lab requirement changes:

- Bicep modules, DCR streams, workbook templates, alert mechanics, Defender/Policy choices, hibernate/activate flow.
- The repo separation: `arc-demo` remains standalone and does not require `sre-agent-demo`.

## Retarget steps

1. Copy `config\demo-skin.json` or `config\dummy-customer.demo-skin.json` to a private runtime file outside git.
2. Set `azure.namePrefix` to 3-20 lowercase letters/digits/hyphens, starting with a letter and ending with a letter/digit. Workload toggles must be JSON booleans, not strings. Missing or malformed skins fail explicitly.
3. Set `notifications.email` to your address or the customer's distribution list.
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

`Remove-ArcDemo.ps1` is cleanup deletion: it deletes both resource groups. Use it
only when the demo should be permanently removed.

Preview either operation with `-WhatIf` first. Removal preserves shared
subscription Defender by default. See [lifecycle.md](lifecycle.md) for exact
scope, retained deployment manifests, optional-workload costs and the readiness
JSON/exit-code contract. Changing skin toggles alone does not delete previously
deployed workloads; lifecycle still accounts for retained manifests.
Keep the chosen runtime target, skin/fleet files and deployment history in your
[private folder](private-config.md) for reactivation; do not copy live IDs/secrets
into the customer skin. Park an attached SRE layer first with its own scripts.

## Examples

Generic default: copy `config\demo-skin.json`, replacing `notifications.email` and supplying the runtime subscription/tenant. Keep real customer names, recipients and resource targets outside tracked source.

Fictitious alternative: `config\dummy-customer.demo-skin.json` changes the prefix to `example-arc`, workbook title to `Example — Hybrid Estate Overview`, turns on Azure VM + Container App, and leaves the optional advanced SQL branch disabled. Replace its example mailbox too.

## Remaining constants

The following strings intentionally remain in code/docs because they identify the reusable spine, not a customer skin: repo names (`arc-demo`, `sre-agent-demo`), feature flags (`SIMULATE_CRASH`, `CRASH_LOOP`), built-in workbook names from the vendored Nic Seilaz library and sample host names (`win-app-01`). Substitute the chosen names in examples; maintained lifecycle scripts use retained IDs and customer-facing defaults from the skin.
