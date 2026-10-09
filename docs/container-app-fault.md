# Container App fault scenario

Optional workload behind `-DeployContainerApps $true`. It creates a lightweight
Container Apps environment `cae-<prefix>`, a tiny HTTP Container App
`ca-<prefix>-fault`, and a metric alert
`alert-<prefix>-containerapp-restarts` routed to the existing Action Group.
The `<prefix>` and workload toggle can come from `config\demo-skin.json`; see
[`reskin-guide.md`](reskin-guide.md).

The app is healthy by default because `SIMULATE_CRASH=false`.

## Deploy

```powershell
.\scripts\Deploy-ArcDemo.ps1 `
  -SubscriptionId <subscription-id> `
  -TenantId <tenant-id> `
  -SkinPath .\config\demo-skin.json `
  -DeployContainerApps $true
```

## Break it

```powershell
az containerapp update `
  --resource-group rg-arc-demo-infra `
  --name ca-arc-demo-fault `
  --set-env-vars SIMULATE_CRASH=true
```

The next revision exits during startup and Container Apps restarts the replica.
Azure Monitor evaluates `RestartCount` every 5 minutes over a 5-minute window
and fires when total restarts are greater than 0. The low threshold is intentional:
Container Apps may restart a failed replica about once per evaluation window, so
`> 0` makes the demo alert deterministic.

## Verify

```powershell
az monitor metrics list `
  --resource "/subscriptions/<subscription-id>/resourceGroups/rg-arc-demo-infra/providers/Microsoft.App/containerApps/ca-arc-demo-fault" `
  --metric RestartCount `
  --interval PT1M `
  --aggregation Total `
  --output table
```

## Repair / reset

```powershell
az containerapp update `
  --resource-group rg-arc-demo-infra `
  --name ca-arc-demo-fault `
  --set-env-vars SIMULATE_CRASH=false
```

With the default prefix, the public endpoint is the `containerAppFqdn` output
from `bicep/main.bicep`. For a custom prefix, replace `arc-demo` in the
resource group and app names with the value passed to `-NamePrefix`.
