# AKS crash-loop scenario

Optional workload behind `-DeployAks $true`. It creates a one-node AKS cluster
`<prefix>-aks` in `australiaeast`, enables Container Insights against the shared
Log Analytics workspace, applies a tiny Kubernetes deployment in namespace
`arc-demo-aks`, and routes the AKS pod restart alert to the existing Action Group.

## Deploy

```powershell
.\scripts\Deploy-ArcDemo.ps1 `
  -SubscriptionId <subscription-id> `
  -TenantId <tenant-id> `
  -AdminEmail you@contoso.com `
  -DeployAks $true
```

The sample deployment is named `crashloop-demo`. It is healthy by default because
`CRASH_LOOP=false`.

## Break it

```powershell
az aks command invoke `
  --resource-group rg-arc-demo-infra `
  --name arc-demo-aks `
  --command "kubectl set env deployment/crashloop-demo -n arc-demo-aks CRASH_LOOP=true"
```

The next pod rollout exits immediately and then restarts. Container Insights
populates `KubePodInventory`; the alert `alert-arc-demo-aks-pod-restarts`
evaluates every 5 minutes over a 15-minute window and emails the Action Group
when restart count or CrashLoopBackOff is observed.

## Verify

```kql
KubePodInventory
| where ClusterName =~ "arc-demo-aks"
| where Namespace == "arc-demo-aks"
| summarize Restarts=max(ContainerRestartCount), Reasons=make_set(ContainerStatusReason) by Name
```

## Repair

```powershell
az aks command invoke `
  --resource-group rg-arc-demo-infra `
  --name arc-demo-aks `
  --command "kubectl set env deployment/crashloop-demo -n arc-demo-aks CRASH_LOOP=false && kubectl rollout status deployment/crashloop-demo -n arc-demo-aks --timeout=180s"
```
