# Cost and lifecycle states

This lab is cost-controlled, not free. Price the selected skin/workloads using the
[Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) and
check actual Cost Management charges in the **confirmed** subscription.
Dated retail examples below are not a current quote or a complete bill.

## Reviewed demo choices (21 October 2026)

The representative core remains **five Windows and three Linux hosts** with
the configured legacy OS mix. SQL-capable host names are not a SQL workload
benchmark or proof of Arc SQL support. Do not remove host roles, Defender,
patching, Change Tracking or alert data to make a smaller bill look equivalent.

The observed eight-host lab already uses Standard HDD OS disks: five 127 GiB
Windows disks and three 30 GiB Linux disks. Its successful warm activation and
fresh 79-check Monitor snapshot show that this tier can support the current
inventory/telemetry rehearsal. They do not benchmark cold boot, sustained SQL
I/O, patch throughput, active AV scanning or a customer production workload.

**Do not make HDD the default for new OS disks.** Microsoft's current guidance
is to stop creating HDD OS disks; support retires **8 September 2028**, followed
by automatic conversion to equivalent Standard SSD with possible disruption.
The fresh-deployment default therefore remains `StandardSSD_LRS`.
An existing HDD lab can deliberately retain its current tier with
`-OsDiskStorageAccountType Standard_LRS` or private skin
`compute.osDiskStorageAccountType`. The same setting is passed to both simulated
Arc and optional native VM modules. Plan HDD migration before retirement.

The deployment wrapper verifies targeted existing OS disks and refuses a tier
mismatch, including in a preview. A new default or skin must never silently
retier an attached disk. Select the **current** tier for reconciliation; this
input is not a conversion command. A separately approved conversion follows
Microsoft's stop/deallocate/change-tier/restart procedure, with associated
downtime and allocation/readiness risks. Hibernate/activate does not convert
disks, and hibernation continues to bill retained storage.

### Qualified retail comparison

The following are **illustrative public retail rates**, retrieved on
21 October 2026 for **Australia East, AUD, Consumption/pay-as-you-go**.
They are not an actual bill or a complete lab forecast. Contract discounts,
tax, credits, eligible license benefits, grants and meter applicability can
change charges. These estimates deliberately exclude unpriced items instead of
inventing a precise all-in total.

| Component | Rate / assumption | Illustrative amount |
|---|---|---|
| Five Windows `Standard_B2as_v2` | AUD 0.1482/VM-hour, Windows product, no license benefit assumed | AUD 0.7410/hour |
| Three Linux `Standard_B2as_v2` | AUD 0.1353/VM-hour, non-Windows product | AUD 0.4059/hour |
| All eight VMs | AUD 1.1469/hour combined | AUD 837.24 at 730 hours, or 201.85 at 176 hours (22 x 8-hour sessions) |
| Retained HDD disk capacity | 5 x S10 (128 GiB billing tier) at 13.4209 + 3 x S4 (32 GiB) at 3.5011/month | AUD 77.61/month |
| Same-capacity SSD disk alternative | 5 x E10 at 18.5996 + 3 x E4 at 4.6499/month | AUD 106.95/month |
| Standard static IPv4 | AUD 0.0071/hour while allocated | AUD 5.18 at 730 hours; NAT gateway and traffic are additional |
| Analytics log ingestion | Marginal paid-tier AUD 4.7582/GB before benefits | Depends on billable ingestion, not VM count |

HDD avoids **AUD 29.34/month in disk capacity charges relative to that SSD
alternative**; it saves **nothing new** on an estate that already has HDD.
Disk operations and any applicable mount/feature charges are excluded from
that capacity comparison. Transactions, disk size and time retained affect the
actual result.

The observed trailing seven days contained about **129.48 MB billable logs
across the shared workspace**, including about 2.93 MB of `App*` telemetry.
At the marginal paid ingestion rate this is about AUD 0.62 before benefits,
not the actual billed amount. The sample includes downtime, rehearsal and
reconstruction; it must not be extrapolated as steady-state customer usage.
Keep the SRE marginal subset separate rather than adding it to the same shared
total twice. Heartbeat was nonbillable in this sample.

### Priority and tradeoffs

1. **Park the complete stack between demos.** Reducing eight-VM runtime from
   730 to 176 hours changes illustrative compute charges by about AUD 635.38,
   before networking savings. This is a scheduling scenario, not a measured
   saving or an automatic 22-day schedule. Use the approved lifecycle order and
   retain a wake-up/rehearsal buffer. VM auto-shutdown alone leaves NAT/PIP and
   optional workloads running.
2. **Retain working HDD deliberately, while planning its retirement.** No live
   conversion, VM reboot or disk deletion is needed merely to encode today's
   effective tier. Keep SSD available for new labs or I/O-sensitive workloads.
3. **Keep existing low-volume telemetry.** The workspace is Analytics,
   30-day default retention; Arc tables observed 30 days while Application
   Insights tables observed 90 days. No lower table plan, retention, sampling,
   stream removal or daily cap is introduced. A cap can stop collection and
   break alerts; tiny current ingestion does not justify weakening the story.
4. **Benchmark before resizing or reducing the fleet.** All eight observed
   VMs use 2 vCPU/8 GiB. Windows CPU p95 was roughly 5.6-9.7% in the limited
   seven-day sample but peaks reached about 83%; boot/patch/agent spikes matter.
   Equivalent Linux counters were not returned by that sizing query.
   Smaller memory/credit-limited SKUs and fewer hosts remain options for a
   separately tested skin, not an equivalent default proved by idle samples.
5. **Preserve required network and workload behavior.** Explicit outbound is
   necessary after deallocation; do not replace NAT with deprecated default
   outbound. Removing a public IP without replacing its egress function breaks
   agents. The optional 0.25-vCPU/0.5-GiB Container App keeps one replica for
   predictable HTTP/fault/alert behavior; scale-to-zero changes availability
   and requires a separate story decision. Consumption grants are shared and
   an environment's retained charges must be checked, not assumed zero.

Defender P2, policies, Windows licensing, alert evaluations, NAT processing,
egress, vault operations, optional Container Apps/environment charges and SRE
charges are **not included** in the compute-plus-storage illustration. Do not
disable paid security or claim license entitlements to reduce its number.
Two retained vaults are not automatically orphaned cleanup candidates. The
read-only alignment review also found live public access disabled versus
source enabled; preserve that live setting pending a separate access decision,
not an incidental cost deployment.

Sources:
[Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices),
[retail endpoint](https://prices.azure.com/api/retail/prices),
[HDD OS retirement](https://learn.microsoft.com/azure/virtual-machines/disks-hdd-os-retirement),
[disk conversion](https://learn.microsoft.com/azure/virtual-machines/disks-convert-types),
[managed disk billing](https://learn.microsoft.com/azure/virtual-machines/disks-understand-billing),
[NAT pricing](https://azure.microsoft.com/pricing/details/azure-nat-gateway/),
[Container Apps billing](https://learn.microsoft.com/azure/container-apps/billing),
[Azure Monitor pricing](https://azure.microsoft.com/pricing/details/monitor/).

## Correcting the previous estimate

The old active line items were 170 + 32 + 75 + 25 + 50 + 5 + 1 = **AUD 358/month**,
not the stated AUD 210. Those unit prices, uptime and ingestion assumptions were
not verified; **358 is an arithmetic correction, not a validated forecast**.
The old hibernated line items summed to 36, not 35. Neither number should be
used for a customer commitment or a subscription budget without repricing.

## What continues to cost money

| State | Compute/network behavior | Remaining costs |
|---|---|---|
| Active | VMs, NAT, and enabled optional workloads run | VM runtime, disks, NAT/PIP, telemetry ingestion/retention, applicable Defender coverage, optional services |
| Hibernated | Exact VM deallocation; optional AKS stopped; Container App revisions inactive; demo NAT/PIP removed | Disks/snapshots, retained data, enabled alert evaluations/notifications and applicable services; optional AKS storage, Container App environment/workload-profile charges where applicable |
| Removed | Both demo groups and named policies/budget verified absent | Delayed usage posting, explicitly retained tenant/shared resources and services outside those groups may still bill |

The nightly VM auto-shutdown schedule does not start VMs in the morning, park AKS,
deactivate Container Apps, or delete NAT. It is not a complete hibernation policy.
Do not assume the desired runtime schedule happened: inspect power state and cost.
Arc records and subscription-wide Defender pricing are distinct from Azure VM
power; do not promise that VM deallocation makes all Defender charges disappear.
Current [Defender billing guidance](https://learn.microsoft.com/azure/defender-for-cloud/faq-defender-for-servers#pricing)
distinguishes Azure deallocated and Arc offline/disconnected servers from online
coverage; retaining the subscription plan does not itself prove every parked
record is billed. Actual entitlement, onboarding model and usage matter.

VM definitions, basic NIC/VNet metadata, Arc inventory and managed identities
need not be deleted to stop pay-as-you-go compute charges. Retaining disks still
costs money; deleting VM definitions adds identity/restoration risk with no extra
VM compute saving over deallocation. Preserve useful logs: 31 days of Analytics
retention is included in ingestion pricing, so reducing below 31 does not save
retention cost ([retention guidance](https://learn.microsoft.com/azure/azure-monitor/logs/data-retention-configure)).
This does not make new ingestion, longer retention or enabled log alerts free.
Automatic alert pausing is deliberately deferred: blindly re-enabling rules on
wake would lose prior disabled state or override concurrent routing decisions.

## Safe cost controls

Use the [lifecycle scripts](lifecycle.md) between demos, with operator approval.
Reduce the fleet or optional workloads before deploying if they are not needed
for the story. The budget is an **alert**, not a spending cap or shutdown trigger.
Keep notification emails and the currency/threshold aligned to the actual
subscription. The default amount 200 is a configurable threshold, not proof the
lab fits within AUD 200.

Do not advise four-day workspace retention (the configured Analytics workspace
uses supported retention settings), snapshot-and-delete as a supported lifecycle
(the scripts do not implement disk restoration), or Defender plan changes without
checking scope/features/prices. Defender prices are commonly quoted per
server/month, not USD 5 or 15 per server-hour.

AKS stop releases capacity; restart may fail if regional capacity is exhausted.
Do not promise a fixed five-minute wakeup for the optional AKS beat. Retain a
demo-prep window and review [Microsoft's stop/start constraints](https://learn.microsoft.com/azure/aks/start-stop-cluster).
