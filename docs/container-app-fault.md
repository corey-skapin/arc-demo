# Container App fault scenario

**Optional scenario/operator procedure, not the default presenter path.**
Start with [the docs index](README.md) and [runsheet.md](runsheet.md).
Use the retained private skin and actual names; merely reading this procedure
does not authorize deployment, break/reset or a notification test.

Optional workload behind `-DeployContainerApps $true`. It creates a lightweight
Container Apps environment `cae-<prefix>`, a tiny HTTP Container App
`ca-<prefix>-fault`, and a metric alert
`alert-<prefix>-containerapp-restarts` routed to the existing Action Group.
The `<prefix>` and workload toggle can come from `config\demo-skin.json`; see
[`reskin-guide.md`](reskin-guide.md).

A fresh deployment defaults to `SIMULATE_CRASH=false`; routine reconciliation
preserves an existing flag. Inspect actual revision/HTTP health rather than
assuming the app is currently healthy.

Break/reset require separate explicit approval, an agreed observation deadline
and an independent fallback reset. Let one operator/companion SRE owner control
the window; do not run competing resets or lifecycle operations.

## Deploy

Add this workload as a **second Deploy pass**: build the base estate first, and once that
deployment has Succeeded set `workloads.deployContainerApps` in the private skin (or pass
`-DeployContainerApps $true`) and run the same Deploy again; see
[adding an optional workload](lifecycle.md#adding-an-optional-workload-to-a-running-estate).
The environment is the slowest single resource in the estate: it normally takes 17-23 minutes, sits in
`Waiting` for 20 minutes or more and can fail on its own with a transient platform error
([troubleshooting](troubleshooting.md#the-container-apps-environment-is-slow-or-fails-with-managedenvironmentprovisioningerror)).
Built in the first pass, such a failure leaves the whole base estate unfinished; built as a second
pass it affects only this optional workload, and the base estate stays complete.

```powershell
.\scripts\Deploy-ArcDemo.ps1 `
  -SubscriptionId <subscription-id> `
  -TenantId <tenant-id> `
  -SkinPath <PRIVATE_SKIN_PATH> `
  -DeployContainerApps $true
```

## Break it

```powershell
az containerapp update `
  --subscription <subscription-id> `
  --resource-group rg-arc-demo-infra `
  --name ca-arc-demo-fault `
  --set-env-vars SIMULATE_CRASH=true
```

The next revision exits during startup and Container Apps restarts the replica.
Azure Monitor evaluates `RestartCount` every 5 minutes over a 5-minute window
and fires when total restarts are greater than 0. The low threshold is intentional:
Container Apps may restart a failed replica about once per evaluation window, so
`> 0` improves visibility. It does not guarantee a fixed alert, delivery or
investigation deadline; retain measured timestamps and bounded fallback recovery.

## Verify

```powershell
az monitor metrics list `
  --subscription <subscription-id> `
  --resource "/subscriptions/<subscription-id>/resourceGroups/rg-arc-demo-infra/providers/Microsoft.App/containerApps/ca-arc-demo-fault" `
  --metric RestartCount `
  --interval PT1M `
  --aggregation Total `
  --output table
```

## Repair / reset

```powershell
az containerapp update `
  --subscription <subscription-id> `
  --resource-group rg-arc-demo-infra `
  --name ca-arc-demo-fault `
  --set-env-vars SIMULATE_CRASH=false
```

With the default prefix, the public endpoint is the `containerAppFqdn` output
from `bicep/main.bicep`. For a custom prefix, replace `arc-demo` in the
resource group and app names with the value passed to `-NamePrefix`.

After reset, verify `SIMULATE_CRASH=false`, the actual healthy serving revision,
latest/latest-ready revision relationship and an HTTP success response. A healthy
replacement revision can precede stateful alert resolution. Distinguish
operator fallback from a verified SRE-executed write; do not infer attribution
from an investigation message.

Hibernation deactivates active revisions without resetting the flag or deleting
the environment. Activation reactivates the latest revision if none is active.
See [lifecycle.md](lifecycle.md); do not substitute minReplicas=0 for parking.
