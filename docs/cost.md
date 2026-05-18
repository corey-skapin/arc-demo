# Cost breakdown

> All figures in **AUD/month** and based on East Australia pricing as of mid-2026.
> Pricing changes — use the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) for current numbers.

## State summary

| State | Cost/month | Trigger |
|---|---|---|
| **Active** (deploy default) | ~AUD 210 | After `Deploy-ArcDemo.ps1` |
| **Hibernated** | ~AUD 35 | After `Hibernate-ArcDemo.ps1` |
| **Removed** | AUD 0 | After `Remove-ArcDemo.ps1` |

## Active state — line items

Assumes the default config (8 VMs, B2as_v2, auto-shutdown at 19:00 local time, leaving roughly 10 hours/day of running time on weekdays and ~5 hours/day on weekends).

| Item | Qty | Unit | ~AUD/mo |
|---|---|---|---|
| Compute — `Standard_B2as_v2` | 8 | ~AUD 50 × ~42% uptime | **~170** |
| OS disks (Standard SSD, 64 GB) | 8 | ~AUD 4 | **~32** |
| **Defender for Servers Plan 2** | 8 | USD 15 × ~42% uptime | **~75** |
| Log Analytics ingestion (perf + events + CT on 8 hosts) | — | ~3 GB/day × AUD 0.30 | **~25** |
| Log Analytics retention (30 days included) | — | — | **0** |
| NAT Gateway | 1 | ~AUD 50 | **~50** |
| NAT public IP (Standard, static) | 1 | ~AUD 5 | **~5** |
| Action Group / Alert / Workbook / Policy / Workspace | — | free at rest | **0** |
| Key Vault (one secret) | 1 | < AUD 1 | **~1** |
| **Total active** | | | **~AUD 210/mo** |

> **Why Defender prorates**: Defender for Servers is billed *per server-hour*. Deallocated VMs aren't billed. So the same scripts give very different numbers depending on whether you leave VMs running 24/7 or use the auto-shutdown.

## Hibernated state — line items

After `Hibernate-ArcDemo.ps1`:
- All 8 VMs deallocated → no compute, no Defender billing.
- NAT Gateway deleted → no networking charge.
- Everything else stays so the demo can wake up in 5-8 min.

| Item | ~AUD/mo |
|---|---|
| OS disks (Standard SSD, 64 GB × 8) | ~32 |
| Log Analytics retention (residual data, decays) | ~3 |
| Key Vault | ~1 |
| **Total hibernated** | **~AUD 36/mo** |

## Removed state

After `Remove-ArcDemo.ps1`: AUD 0. Both RGs gone, policy assignments deleted, budget removed, SPN removed, Defender reverted to Free (unless `-KeepDefender`).

## Knobs you can turn

### Lower the active cost

- **Run fewer / shorter VMs**: `-WindowsVmCount 3 -LinuxVmCount 2` cuts compute + Defender by ~40%.
- **Drop Defender to Plan 1**: ~USD 5/server-hour instead of USD 15. You lose vulnerability assessment richness — the workbook tile loses its CVSS data. Edit `bicep/modules/defender.bicep` and change `subPlan` to remove it.
- **Smaller VMs**: only worth it if you can find a working sub-B2 SKU (rarely available in AU regions).
- **Shorter retention** on LAW: 4 days instead of 30 (`retentionInDays` in `bicep/modules/workspace.bicep`).

### Lower the hibernated cost

- **Snapshot + delete OS disks**: snapshots are ~25% the cost of running disks. Total drops to ~AUD 15/mo but restore time goes from 5 min to ~10 min. Not built into the scripts but easy to add.
- **Use Standard HDD** instead of Standard SSD for OS disks: ~AUD 8/mo total instead of AUD 32 (4 GB lower performance — your demo VMs boot slower, may cause AMA reconnect delays).

### Cost alerts

The default budget alerts at AUD 200/mo with email at 50/80/100% actual + 100% forecast. Tune:

```powershell
.\scripts\Deploy-ArcDemo.ps1 -BudgetAmount 100 ...
```

## Sanity-check your bill

```powershell
# Cost so far this month, filtered to the demo RGs
az consumption usage list `
  --start-date (Get-Date -Day 1 -Format yyyy-MM-dd) `
  --end-date   (Get-Date -Format yyyy-MM-dd) `
  --query "[?contains(instanceName,'arc-demo')].{day:usageStart,resource:instanceName,cost:pretaxCost,meter:meterName}" `
  -o table
```

If the bill looks wildly off from this guide, the most likely cause is **forgetting to hibernate after a demo** + Defender Plan 2 racking up 24/7 charges. Set a calendar reminder, or wire up a Logic App on the budget alert to auto-hibernate at 80% (left as an exercise — would be a nice follow-up PR).
