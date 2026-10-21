# AKS crash-loop scenario

**Optional scenario/operator procedure, not a presenter prerequisite.**
Use [the docs index](README.md) to choose the default read-only tour.
Use the retained private skin and actual names; this document is not approval
to deploy, execute cluster commands or send alert notifications.

Optional workload behind `-DeployAks $true`. It creates a one-node AKS cluster
`<prefix>-aks` in the chosen region (default `australiaeast`), enables Container Insights against the shared
Log Analytics workspace, applies a tiny Kubernetes deployment in namespace
`arc-demo-aks`, and routes the AKS pod restart alert to the existing Action Group.
The prefix, region, and AKS toggle can come from `config\demo-skin.json`; see
[`reskin-guide.md`](reskin-guide.md).
This workload was absent from the verified eight-host active lab; its optional
deployment and stop/start path are not implied to be live-validated.
Break/reset require a separately approved bounded window and fallback plan.

## Deploy

```powershell
.\scripts\Deploy-ArcDemo.ps1 `
  -SubscriptionId <subscription-id> `
  -TenantId <tenant-id> `
  -SkinPath <PRIVATE_SKIN_PATH> `
  -DeployAks $true
```

The sample deployment is named `crashloop-demo`. It is healthy by default because
`CRASH_LOOP=false`.

## Break it

```powershell
az aks command invoke `
  --subscription <subscription-id> `
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
| where TimeGenerated > ago(15m)
| where ClusterName =~ "arc-demo-aks"
| where Namespace == "arc-demo-aks"
| summarize Restarts=max(ContainerRestartCount), Reasons=make_set(ContainerStatusReason) by Name
```

## Repair

```powershell
az aks command invoke `
  --subscription <subscription-id> `
  --resource-group rg-arc-demo-infra `
  --name arc-demo-aks `
  --command "kubectl set env deployment/crashloop-demo -n arc-demo-aks CRASH_LOOP=false && kubectl rollout status deployment/crashloop-demo -n arc-demo-aks --timeout=180s"
```

Lifecycle discovery follows retained cluster IDs, not the current skin toggle.
Hibernation stops an existing cluster; activation starts it without resetting
`CRASH_LOOP`. Capacity and stop/start timing restrictions still apply; see
[lifecycle.md](lifecycle.md).
