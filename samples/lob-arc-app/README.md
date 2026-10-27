# LOB Arc bridge sample app

This tiny PowerShell worker is the T11 sample line-of-business app for the
Arc + Azure Monitor + Azure SRE Agent demo. It is designed to run on a Windows
Arc-enabled server from [`arc-demo`](../../README.md)
and emit Monitor-friendly Application events.

The sample lives in this public repo so Azure SRE Agent can use it as application
code context during the LOB-on-Arc incident demo. It does not make `arc-demo`
depend on SRE Agent; it is source context only.

## Fault modes

The runtime reads `C:\ProgramData\ArcSreLobApp\appsettings.json`:

| FaultMode | Behavior | Monitor signal |
|---|---|---|
| `Healthy` | Writes periodic heartbeat events and text logs. | Event ID `4000` Information |
| `Degraded` | Writes warning events but keeps running. | Event ID `4200` Warning |
| `CrashOnProcessing` | Writes an error event and exits with code 42. | Event ID `4100` Error plus stopped scheduled task |

## Showing healthy activity in Log Analytics

The Arc core DCR collects Application/System warnings and errors, plus a narrow
exception for Application event `4000`, Information, provider `ArcLobBridgeApp`.
It does not collect all informational Application events. With the default
15-second loop and heartbeat every four cycles, a running healthy worker writes
about one heartbeat per minute; ingestion charges and propagation delays apply.
The optional sample is not installed or started by Arc deployment or readiness.

For an existing lab with the older DCR, obtain approval for the single-selector
collection change; do not redeploy the lab or induce a fault just to show logs.
Source presence or old error events do not prove the worker is running today.
Verify fresh records after the approved preparation, with the Logs time picker
covering the query window:

```kusto
Event
| where TimeGenerated > ago(30m)
| where Source =~ "ArcLobBridgeApp" and EventLog == "Application"
| where EventID == 4000
| project TimeGenerated, Computer, EventID, EventLevelName, RenderedDescription
| order by TimeGenerated desc
```

Filter `Computer` to the confirmed deployment host when more than one sample is
present. Missing healthy events can mean collection is not updated, ingestion is
pending, or the worker is not emitting; inspect approved evidence rather than
assuming the app stopped. Warning `4200` and error `4100` are separate,
explicitly approved fault scenarios, not healthy-heartbeat substitutes.

## How it is deployed

Do not run this directly from the repo during the demo. After separately
approving the deployment/guest execution scope, use the companion
`sre-agent` repository's helper to deploy
it to an Arc-enabled Windows server:

```powershell
.\scripts\Invoke-LobArcAppOnArc.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json `
  -Action Deploy `
  -SourceRepositoryUrl <ARC_REPOSITORY_URL> `
  -SourceCommit <PINNED_SOURCE_COMMIT_SHA> `
  -SourcePath samples/lob-arc-app/LobArcBridgeApp.ps1
```

The deploy helper stamps the repository URL, commit, and source path into the app
config and event messages so an SRE investigation has public code context.
The pin must identify the source actually deployed, not merely this repo's
current HEAD. Source presence alone does not prove the guest workload is running.
The example source-context JSON contains placeholders, not a usable deployment
pin. Supply the chosen repository/commit privately at runtime; do not replace
the tracked example with personal or customer-specific context.

## SRE Agent knowledge-base setup

For the LOB-on-Arc demo:

1. Follow the companion repo's current knowledge-base/code-context setup for its parent agent; portal navigation can change.
2. Register the operator-supplied `<ARC_REPOSITORY_URL>` using that procedure.
3. Verify access/indexing and the deployed source pin rather than assuming a URL alone supplies working context.
4. Confirm the investigation can actually cite `samples/lob-arc-app/LobArcBridgeApp.ps1`. Code context is not proof of an executed repair.

## Relationship to the demo repos

| Repo | Purpose |
|---|---|
| `arc-demo` | Deploys Arc + Azure Monitor spine. |
| `sre-agent` | Deploys SRE Agent layer and T11 helper scripts. |
| `arc-demo/samples/lob-arc-app` | Provides LOB app source code context for SRE Agent RCA. |
