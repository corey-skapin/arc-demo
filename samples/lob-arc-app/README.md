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
| --- | --- | --- |
| `Healthy` | Writes periodic heartbeat events and text logs. | Event ID `4000` Information |
| `Degraded` | Writes warning events but keeps running. | Event ID `4200` Warning |
| `CrashOnProcessing` | Writes an error event and exits with code 42. | Event ID `4100` Error plus stopped scheduled task |

### Bounded warning rehearsal

The companion helper's `WarnForDuration -WarningSeconds 120 -ApproveWarningWindow`
runs one bounded warning window. Pass `-ApproveWarningWindow` to confirm the host,
duration and alert/notification effects.
The helper requires a Healthy running worker, temporarily selects Degraded, restores the
exact original configuration in `finally`, and verifies the original worker/task
without restarting or killing it. After an interruption or a concurrent change,
inspect the host yourself: nothing retries the fault or resets it automatically.

On **2 November 2026 UTC**, one window ran from 00:27:32 to 00:29:32; the original
configuration was restored with the same worker PID.
Eight real `4200` events arrived in Log Analytics. The existing Sev2 alert fired
at 00:28:39, its Action Group executed that second, and an automatic Review-only
SRE thread ran from 00:29:41 to a final narrative at 00:31:10. Independent Status
confirmed Healthy/running, and a post-restoration `4000` at 00:30:21 was ingested
at 00:31:00. No task restart, guest repair or second fault was performed.

**First-run narrative limits:** SRE incorrectly inferred an ongoing warning from the last
ingested `4200` and overstated how strongly sparse host data ruled out pressure.
Prefer the actual cleanup/current Status and fresh `4000` evidence. A still-Fired
alert inside its ten-minute lookback is not proof of a current app fault;
Acknowledged is not Resolved. Email receipt and a real upstream dependency
failure were not proven. This is a configuration-driven warning and investigation,
not an app-to-SQL transaction or automatic remediation.

#### Representative follow-up

A single repeat on **2 November 2026 UTC** used the existing
120-second helper, unchanged pinned app and a neutral temporary Sev2 rule.
Fresh Healthy/original-worker, ingested `4000` and zero-alert gates passed first.
The helper's start is a pre-write boundary, not a separately measured file-write
timestamp; the original configuration was restored about 122 seconds later.

| Evidence | UTC |
| --- | --- |
| Helper start / warning window end | 02:19:20.766 / 02:21:21.270 |
| Original configuration restored and worker verified | 02:21:22.758 |
| First / last warning generated | 02:19:23.603 / 02:21:08.652 |
| First / last warning ingested | 02:19:59.867 / 02:21:40.004 |
| First resumed `4000` generated / ingested | 02:21:23.672 / 02:22:03.603 |
| Independent Healthy/original-worker Status | 02:24:38.323 |
| Temporary-rule alert fired / Action Group executed | 02:24:59.886 / 02:25:00.369 |
| Companion automatic Review investigation finished | 02:28:43 |

All eight local `4200` events were ingested; the exact deployed alert KQL matched
eight records. The original process, running task, pinned source and configuration
were retained without restart, kill, redeployment or repair.

The companion capture reported an evidence-led result: warnings followed by
resumed healthy activity, ranked change evidence from actual read-only Run
Command/Status output, and qualified dependency/customer-impact and sparse-counter
limits. Audit truncation prevents full verification of some returned values. This
does not prove a real downstream outage, email receipt or automatic repair.

This run used a temporary alert route, so it is not proof of default
repeat-within-cooldown behavior.

## Showing healthy activity in Log Analytics

The Arc core DCR collects Application/System warnings and errors, plus a narrow
exception for Application event `4000`, Information, provider `ArcLobBridgeApp`.
It does not collect all informational Application events. With the default
15-second loop and heartbeat every four cycles, a running healthy worker writes
about one heartbeat per minute; ingestion charges and propagation delays apply.
The optional sample is not installed or started by Arc deployment or readiness.

An existing lab with the older DCR needs the single-selector collection change;
do not redeploy the lab or induce a fault just to show logs.
Source presence or old error events do not prove the worker is running today.
Verify fresh records after that change, with the Logs time picker
covering the query window:

```kusto
Event
| where TimeGenerated > ago(30m)
| where Source =~ "ArcLobBridgeApp" and EventLog == "Application"
| where EventID == 4000
| project TimeGenerated, Computer, EventID, EventLevelName, RenderedDescription
| order by TimeGenerated desc
```

Filter `Computer` to the host you deployed the sample to when more than one sample is
present. Missing healthy events can mean collection is not updated, ingestion is
pending, or the worker is not emitting; inspect the evidence rather than
assuming the app stopped. Warning `4200` and error `4100` are separate
fault scenarios, not healthy-heartbeat substitutes.

## How it is deployed

Do not run this directly from the repo during the demo. Use the companion
`sre-agent-demo` repository's helper to deploy
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
2. Register your `<ARC_REPOSITORY_URL>` using that procedure.
3. Verify access/indexing and the deployed source pin rather than assuming a URL alone supplies working context.
4. Confirm the investigation can actually cite `samples/lob-arc-app/LobArcBridgeApp.ps1`. Code context is not proof of an executed repair.

## Relationship to the demo repos

| Repo | Purpose |
| --- | --- |
| `arc-demo` | Deploys Arc + Azure Monitor spine. |
| `sre-agent-demo` | Deploys SRE Agent layer and T11 helper scripts. |
| `arc-demo/samples/lob-arc-app` | Provides LOB app source code context for SRE Agent RCA. |
