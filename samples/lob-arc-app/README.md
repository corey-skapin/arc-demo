# LOB Arc bridge sample app

This tiny PowerShell worker is the T11 sample line-of-business app for the
Arc + Azure Monitor + Azure SRE Agent demo. It is designed to run on a Windows
Arc-enabled server from [`corey-skapin/arc-demo`](https://github.com/corey-skapin/arc-demo)
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

## How it is deployed

Do not run this directly from the repo during the demo. After separately
approving the deployment/guest execution scope, use the companion
[`sre-agent-demo`](https://github.com/corey-skapin/sre-agent-demo) helper to deploy
it to an Arc-enabled Windows server:

```powershell
.\scripts\Invoke-LobArcAppOnArc.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json `
  -Action Deploy `
  -SourceRepositoryUrl https://github.com/corey-skapin/arc-demo `
  -SourceCommit <PINNED_SOURCE_COMMIT_SHA> `
  -SourcePath samples/lob-arc-app/LobArcBridgeApp.ps1
```

The deploy helper stamps the repository URL, commit, and source path into the app
config and event messages so an SRE investigation has public code context.
The pin must identify the source actually deployed, not merely this repo's
current HEAD. Source presence alone does not prove the guest workload is running.

## SRE Agent knowledge-base setup

For the LOB-on-Arc demo:

1. Follow the companion repo's current knowledge-base/code-context setup for its parent agent; portal navigation can change.
2. Register `https://github.com/corey-skapin/arc-demo` using that procedure.
3. Verify access/indexing and the deployed source pin rather than assuming a URL alone supplies working context.
4. Confirm the investigation can actually cite `samples/lob-arc-app/LobArcBridgeApp.ps1`. Code context is not proof of an executed repair.

## Relationship to the demo repos

| Repo | Purpose |
|---|---|
| `corey-skapin/arc-demo` | Deploys Arc + Azure Monitor spine. |
| `corey-skapin/sre-agent-demo` | Deploys SRE Agent layer and T11 helper scripts. |
| `corey-skapin/arc-demo/samples/lob-arc-app` | Provides LOB app source code context for SRE Agent RCA. |
