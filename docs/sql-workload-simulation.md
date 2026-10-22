# SQL workload simulation

This optional beat gives the Arc demo a DBA-relevant signal without claiming
**SQL Server enabled by Azure Arc**.
It is an optional operator procedure, not required presenter reading; start at
[the docs index](README.md) and [runsheet.md](runsheet.md).
Use the retained private skin and actual host name for approved operations.

## What it is

`samples\sql-workload\SqlWorkloadSimulator.ps1` is a small PowerShell worker that
runs on `win-sql-01` as a scheduled task. It emits SQL-shaped Windows Application
events and a text log:

| Fault mode | Behavior | Event |
|---|---|---|
| `Healthy` | Periodic "orders database responsive" heartbeat | `5000` Information |
| `Blocking` | Repeated blocking-chain warnings | `5200` Warning |
| `ConnectionTimeout` | Error event and process exit code 51 | `5100` Error |

It is a workload simulation. It does **not** install SQL Server and does **not**
register SQL Server enabled by Azure Arc.
The source's presence is not proof that the simulator is installed/running.
Deployment, fault/reset and removal require their own scoped approval.
Even Status/CollectLogs use guest Run Command execution, not ARM-only inspection.

## Why this exists

The default Azure-only lab uses Azure VMs Arc-enabled with `MSFT_ARC_TEST=true` to
mimic on-prem servers. That is fine for server/Monitor demos, but SQL Server
enabled by Azure Arc lists SQL Server in Azure VMs as unsupported. This simulator
keeps the useful SQL operations story while avoiding unsupported product claims.

## Deploy the simulator

```powershell
# Run from the arc-demo repository root.

.\scripts\Invoke-SqlWorkloadOnArc.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_SKIN_PATH> `
  -MachineName win-sql-01 `
  -Action Deploy
```

Check status:

```powershell
.\scripts\Invoke-SqlWorkloadOnArc.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_SKIN_PATH> `
  -MachineName win-sql-01 `
  -Action Status
```

## Induce a SQL-shaped fault

Connection timeout:

```powershell
.\scripts\Invoke-SqlWorkloadOnArc.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_SKIN_PATH> `
  -MachineName win-sql-01 `
  -Action InduceFault `
  -FaultMode ConnectionTimeout
```

Blocking/degradation:

```powershell
.\scripts\Invoke-SqlWorkloadOnArc.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_SKIN_PATH> `
  -MachineName win-sql-01 `
  -Action InduceFault `
  -FaultMode Blocking
```

Reset:

```powershell
.\scripts\Invoke-SqlWorkloadOnArc.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_SKIN_PATH> `
  -MachineName win-sql-01 `
  -Action ResetFault
```

## KQL

```kql
Event
| where TimeGenerated > ago(30m)
| where EventLog =~ "Application"
| where Source == "ArcSqlWorkloadDemo"
| project TimeGenerated, Computer, EventID, EventLevelName, RenderedDescription, _ResourceId
| order by TimeGenerated desc
```

## Talk track

Use:

> This is a SQL-shaped workload signal from an Arc-enabled Windows server. It shows
> how a DBA-relevant application or database symptom can enter Azure Monitor and
> SRE-assisted diagnostics through Arc.

Avoid:

> This validates SQL Server enabled by Azure Arc.

Avoid:

> This is a real SQL Server BPA/Defender inventory demo.

## Cleanup

Remove only under explicit approval. Hibernation parks the VM and preserves the
simulator configuration/task and its fault mode; it is not simulator removal.

```powershell
.\scripts\Invoke-SqlWorkloadOnArc.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_SKIN_PATH> `
  -MachineName win-sql-01 `
  -Action Remove
```
