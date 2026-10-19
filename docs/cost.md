# Cost and lifecycle states

This lab is cost-controlled, not free. Price the selected skin/workloads using the
[Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) and
check actual Cost Management charges in the **confirmed** subscription.
No current price quote is implied by these docs.

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
| Hibernated | Exact VM deallocation; optional AKS stopped; Container App revisions inactive; demo NAT/PIP removed | Disks/snapshots, retained data and applicable Defender/subscription services; optional AKS storage, Container App environment/workload-profile charges where applicable |
| Removed | Both demo groups observed deleted | Delayed usage posting, retained tenant/shared resources and services outside those groups may still bill |

The nightly VM auto-shutdown schedule does not start VMs in the morning, park AKS,
deactivate Container Apps, or delete NAT. It is not a complete hibernation policy.
Do not assume the desired runtime schedule happened: inspect power state and cost.
Arc records and subscription-wide Defender pricing are distinct from Azure VM
power; do not promise that VM deallocation makes all Defender charges disappear.

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
