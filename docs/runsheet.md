# Arc: from servers to an operational view

**Presenter:** open the generated `.local/presenter-runsheet.md` and follow this
page from top to bottom. Its links and queries are already filled in. This tracked
file is the source template, not a second presentation.

Context recorded **{{RecordedAtUtc}}**; document generated **{{GeneratedAtUtc}}**.
Generation is offline, not a fresh readiness or application-health check.
The preparing operator verifies readiness before handing over this page.

Allow **25-30 minutes** for this Arc path (the scene times below add up to 28; each
optional beat adds about a minute). The SRE guide it hands over to has its own
timing. Everything on this Arc path is read-only: do not start machines, run
assessments, select **Check for updates**, change configuration, send test emails,
approve anything or induce a fault here. Live faults, fresh investigations and the
Review approval belong to the SRE half, with their own approvals.

| # | Scene | Minutes | Evidence |
| --- | --- | --- | --- |
| 1 | Understand the estate | 3 | Live |
| 2 | Find a server and check its data is current (engineer task 1) | 5 | Live |
| 3 | SQL under the same view: a real workload, then nested Arc SQL | 5 | Live; nested Arc SQL is experimental |
| 4 | Capacity and headroom (engineer task 2) | 3 | Live |
| 5 | Optimisation opportunities (engineer task 2) | 3 | Live |
| 6 | From signal to alert (engineer task 3 starts here) | 5 | Alert rules live; incidents live or dated in the SRE half |
| 7 | Operating posture | 2 | Live |
| 8 | Close and hand over | 2 | Recap |

**Live** means the page reads current Azure data when you open it. **Recorded**
means dated evidence from an earlier approved run: say its date and never present
it as happening now. Anything that needs a command is in the
[operator notes](#operator-notes) at the end, not in what you say.

## 1. Understand the estate (3 minutes, live)

Open [the estate workbook]({{workbookUrl}}).

**Say:** "We want one operational view of servers outside Azure: what is
connected, how it is performing, what changed, and what needs attention."

Show **Estate connectivity (last 15m)**, **Hosts beating over time (24h)** and
**Per-host CPU utilisation (24h)**. Then show **Configuration changes (24h)**,
**Linux syslog activity (24h)** and **Tagging hygiene (Arc machines)**.
**Estate connectivity** counts the hosts that send a heartbeat: a parked machine,
or one with no monitoring agent (the nested SQL guest in scene 3 is one), is not in
that count, and the Arc list in scene 2 is the full inventory. A parked period
reads as no hosts beating, which is expected and is not continuous uptime. If
**Tagging hygiene** lists an untagged machine, say why it is untagged. If a tile is
empty, say so and use the [fallback queries](#fallback-queries).

This lab simulates on-premises servers using Azure VMs and `MSFT_ARC_TEST=true`.
It is a demo, not a hardened production architecture or blanket feature validation.

## 2. Find a server and check its data is current (5 minutes, live)

**Engineer task 1:** find a server or workload and see whether its data is current.

Open [the Arc resource group]({{ResourceGroupUrl}}) to see every Arc machine and
the SQL Server instances in one list (narrow it with the **Type** filter), or
search the portal for **Azure Arc** and select **Machines** under
**Infrastructure**. Windows hosts, Linux hosts and SQL hosts sit in one list with
the same **Status**, tags and Azure identity. A machine that shows **Disconnected**
is expected only if it is parked on purpose: say which one and why.

Open [the Windows Arc machine]({{windowsMachineUrl}}), **{{windowsMachineName}}**:
show its connection state, operating system and tags. Then open
[the Linux Arc machine]({{linuxMachineUrl}}), **{{linuxMachineName}}**.

**Say:** "Arc gives each server an Azure resource identity without making it an
Azure VM. Windows or Linux, it is found, tagged and governed the same way."

These are Arc resources, not the lab's backing VMs. Tags describe intent; they do
not prove compliance, active antivirus or a purchased licence. Stay on
**Overview**, **Updates** and tags, and do not open a machine's **Extensions**
page. In this lab the Windows hosts get the Azure Monitor Agent as an Arc
extension, but the Linux hosts get it, and Change Tracking, as Azure VM extensions:
an artifact of simulating on-premises servers with Azure VMs. A real on-premises
server gets the agent as an Arc extension and authenticates with the Arc machine's
managed identity.

Now ask "is its data current?" without logging in to the server. Open
[the workspace]({{workspaceUrl}}), **{{workspaceName}}**, and select **Logs**.
If needed, switch **Simple mode** to **KQL mode**. Paste the prepared query,
select **Run** and use the stated time range.

**Last 10 minutes: who is reporting right now?**

```kusto
Heartbeat
| where TimeGenerated > ago(10m)
| where tolower(_ResourceId) startswith "{{ArcScope}}/providers/microsoft.hybridcompute/machines/"
| summarize LastHeartbeat=max(TimeGenerated) by Computer, OSType
| order by Computer asc
```

**Say:** "From the estate view to a timestamped answer, without logging in to each
server." Point to a real reporting host and its **LastHeartbeat**.

A missing host is missing evidence, not zero-valued success. A parked machine, or
one with no monitoring agent (the nested SQL guest in scene 3 is one), does not
appear.

**Optional per-server view (adds about a minute):**
{{MachineIntelligenceAvailability}}
Pick a Windows host: most tiles populate. The SQL instance and vulnerability tiles
stay empty on a host with no Arc-enabled SQL Server or Defender findings, so say so
rather than scrolling past them. This workbook's memory and disk charts read a
table only the Windows hosts have; the capacity workbook (scene 4) is where Linux
memory and disk show.

### 2b. How the data gets here (1 minute)

{{DataCollectionRuleAvailability}}

Show its **Resources** (the machines it applies to) and **Data sources**.

**Say:** "The Azure Monitor Agent collects the telemetry. The data collection rule
is the control plane: it says what to collect and where to send it. One rule serves
many machines, and its selectors keep ingestion small; the Windows event selectors
are split by level, so nothing is collected twice. We extended this rule during the
build, adding the Linux memory and disk counters and the SQL events, and the data
followed within a couple of minutes."

Read-only: do not edit the rule, and say nothing about cost savings.

## 3. SQL under the same view (5 minutes)

SQL is a workload on a Windows server, not a third operating system. Two different
things are shown here and they are different evidence: a real SQL Server workload
that Azure Monitor observes (3a), and a SQL Server instance that Azure Arc
inventories (3b).

### 3a. A real SQL workload observed by Azure Monitor (2 minutes, live)

{{SqlAvailability}}

When prepared, show the linked engine/database query result, including edition,
version, actual row count and commit timestamp. Then, in the same workspace Logs
window, select **Last 30 minutes**:

```kusto
Event
| where TimeGenerated > ago(30m)
{{SqlHostFilter}}
| where Source =~ "ArcSqlEngineDemo" and EventID == 6000
| project TimeGenerated, Computer, EventLevelName, RenderedDescription
| order by TimeGenerated desc
```

**Say:** "This worker really commits orders to SQL Server and reads them back.
Arc and Monitor carry its operational evidence. This is a real SQL Server workload
on an Arc-monitored server; it does not validate Arc-enabled SQL Server inventory,
best practices assessment or Defender for SQL."

Fresh Information rows (about one a minute) corroborate the saved query result; old
evidence or SQL-shaped simulator events do not prove a running engine today. No
rows means a gap: say so. Do not install, restart or change collection.

### 3b. Nested Arc-enabled SQL Server, experimental (3 minutes, live)

{{NestedSqlAvailability}}

Open the nested guest's Arc machine from the links above: it has its own Arc
identity and **Status** **Connected**. Then open its SQL Server instance and show
its status, SQL Server version and edition. Under **Data management** select
**Databases** and show the discovered databases with **Last collected time** and
**Upload status**.

**Say:** "This guest has its own Arc identity and an Arc-enabled SQL Server
instance. Azure Arc gives us the instance, its version and its databases in the
same place as every other server. We run it in license-only mode, so what you see
is connection and inventory, not monitoring or assessment."

**Say the boundary before you are asked:** "This is experimental. SQL Server on
Azure virtual machines is not a supported Arc SQL configuration and this guest
runs nested on an Azure VM, so it shows how the experience works, not production
or support validation."

- Do not claim Monitoring, best practices assessment or Defender for SQL on this
  instance, and do not open those panes: they are not enabled or verified for it
  in this lab.
- Subscription-level Defender settings can add the Defender extensions, and a
  Protected status, to a host independently of this lab. If asked, say: "that is
  present through subscription-level Defender settings; we make no Defender claim
  for an experimental nested guest."
- Inventory can lag; database changes appear in the portal within about an hour.
  Judge freshness by **Last collected time**, not by the guest being up.
- If the guest or instance shows **Disconnected** or **Expired**, or has no
  databases, say it is not available in this run and move on. The presenter never
  starts or repairs it.
- The guest runs on a Hyper-V parent host that is itself an Azure VM, a disclosed
  lab detail. In the capacity workbook (scene 4) the parent and the guest are
  separate rows and are never added together.

## 4. Capacity and headroom (3 minutes, live)

**Engineer task 2:** open the capacity view and drill into the evidence.

{{CapacityWorkbookAvailability}}

1. **Scope and evidence quality** (the first row of tiles): machines in scope, how
   many are reporting now, how old the latest sample is, how many have adequate
   evidence and how much of the window each covers. A parked or thin-history
   estate reads as a plain message, not an error.
2. **Where should engineers look first?** (the second row and the status grid):
   pressure, apparent headroom, insufficient evidence and no telemetry, with
   colour-coded status and evidence columns. A brief spike is not pressure; a
   sustained run is.
3. **CPU** tab: the 95th-percentile chart (what a host does most of the time)
   beside the peak chart (the spikes), with the dashed threshold. The table
   separates sustained pressure from brief spikes.
4. **Memory** and **Disk** tabs: Linux memory and disk report alongside Windows.
   A counter with too little history is labelled thin, never guessed.
5. If the nested guest is part of this run, select its parent host in the status
   grid. The parent's own operating-system counters do not reflect the guest's
   load, so it reads *Insufficient evidence*, never headroom, and the guest says it
   has no telemetry.

**Say:** "Before anyone is told to resize anything, we look at how much evidence we
have: how long, how complete, how sustained. This view says when it does not know."

The thresholds on the page are illustrative and editable, and the evidence rule is
modest for a lab that runs on demand. Missing data is not zero and parked gaps are
not idle headroom; low CPU alone is not a sizing instruction. Parent and guest rows
are separate observations, never additive hardware capacity.

## 5. Optimisation opportunities (3 minutes, live)

**Engineer task 2, continued:** from capacity to "which machines deserve a
conversation".

{{OptimisationWorkbookAvailability}}

1. **Opportunity tiles:** machines to review per reason (low utilisation,
   scheduling, consolidation, ownership gaps, not reporting). A machine can carry
   several reasons. These are conversation starters, not savings.
2. **Reasons by evidence quality:** which flags rest on adequate evidence and which
   on limited evidence.
3. **Review candidates:** select one machine. The review card explains each reason,
   the evidence window, what is still missing, the published owner tags, the next
   human decision and what the workbook will never do.
4. **Scheduling and scenario:** the heat-map shows when the machine is idle. For a
   worked example, enter an illustrative baseline and the share that scales with
   running hours; the labelled scenario shows the effect of fewer running hours.
5. **Consolidation:** groups side by side, peaks never added, with a link back to
   the capacity workbook for the capacity evidence.

**Say:** "This tells us which servers deserve a conversation, why they were
flagged and what we still do not know. The decision stays with a person."

A stale or non-reporting machine is not safe to delete or redundant. The scenario
inputs are hypothetical: not billing, not realised savings and not on-premises
cost. Observation here is separate from approval, and there is no remediation or
delete button.

## 6. From signal to alert (5 minutes)

**Engineer task 3 starts here:** open an incident, read the investigation and
review a narrowly scoped proposed action. The investigation itself is in the SRE
guide that follows this one.

### 6a. A healthy application signal (1 minute, live)

{{LobAvailability}}

In the same Logs window, select **Last 30 minutes**:

```kusto
Event
| where TimeGenerated > ago(30m)
| where tolower(_ResourceId) startswith "{{ArcScope}}/providers/microsoft.hybridcompute/machines/"
{{LobHostFilter}}
| where Source =~ "ArcLobBridgeApp" and EventID == 4000
| project TimeGenerated, Computer, EventLevelName, RenderedDescription
| order by TimeGenerated desc
```

**Say:** "This is the healthy business worker processing transactions, not just an
agent heartbeat."

Expect a fresh Information event roughly every minute. If there are no rows, state
the gap and skip this beat. Do not show an earlier incident as today's activity.

### 6b. From evidence to a routed alert (2 minutes, live configuration)

Open [the missing-heartbeat alert rule]({{heartbeatAlertUrl}}),
**{{heartbeatAlertName}}**. Show its scope, condition, severity and evaluation
window. Then open [the action group]({{actionGroupUrl}}), **{{actionGroupName}}**,
to show the configured notification route without exposing the recipient or
selecting **Test**.

**Say:** "We turn signals into a routed operational action. Email is configured
here; an integration or delivered notification needs its own evidence."

The demo rule evaluates observed Heartbeat rows, not a complete never-seen-host
inventory. Do not promise complete outage detection or a fixed notification time.
If alert history is populated, show the affected resource and timestamp. A healthy
lab may have no fired alerts: show the rule, not a manufactured outage.

### 6c. The SQL and application alerts (2 minutes, rules live)

{{SqlIncidentAvailability}}

{{LobIncidentAvailability}}

Show each rule's scope, condition and severity.

**Say:** "These alerts use the same action group. When the SQL worker logs a lock
timeout, or the application worker reports a degraded state, an alert fires and the
SRE agent starts an investigation automatically. The incidents we walk through next
are the SRE agent's own: any we trigger live are current, earlier ones are dated."

If the alert history or an investigation is absent, state that gap and do not
manufacture evidence. Nothing is triggered from this Arc path: incidents are
triggered, approved and read in the SRE half.

## 7. Operating posture (2 minutes, live)

Return to [the Windows Arc machine]({{windowsMachineUrl}}). Show its available
**Updates** assessment/status view; point to **Last assessed** and actual
missing-update rows, not just an enabled extension.

**Say:** "Visibility comes before a planned change. We can see update and
configuration posture centrally, then agree the action and maintenance window."

If there is no assessment data, say so and move on; do not select **Check for
updates**, install updates or alter schedules. Update Manager is free for Azure VMs
but billed for Arc-enabled servers, so do not describe it as free (exceptions are
in the [pricing FAQ](https://learn.microsoft.com/azure/update-manager/update-manager-faq#pricing)).
Policy assignment is not evaluated compliance. Monitor readiness is not active AV,
full EDR, patch completion or application proof. Arc-enabled SQL Server inventory
is shown only for the nested guest, in license-only mode; best practices
assessment, Monitoring and Defender for SQL are not demonstrated on any host.

**Optional governance view (adds about a minute):**
{{ComplianceWorkbookAvailability}}
Show the policy compliance score. This lab is intentionally un-hardened, so a low
score is the honest baseline rather than a failure of the demo: visibility first,
then an agreed change. Do not read out the workbook's patch scorecard: it is a
heuristic from connection state, not an Update Manager assessment, so use the
**Updates** view above for patching. Do not open the experimental governance
workbook; some of its tiles are empty by design.

## 8. Close and hand over (2 minutes)

Return to [the estate workbook]({{workbookUrl}}).

**Say:** "Arc provides the identity. Monitor provides evidence and alerts.
Engineers get a few prepared views for the routine questions, and a clear approval
boundary."

Recap the three engineer tasks. None needs a terminal, a subscription ID or
hand-written queries.

| Engineer task | Where |
| --- | --- |
| 1. Find a server or workload and see whether its data is current | Scene 2 |
| 2. Open the capacity or optimisation view and drill into the evidence | Scenes 4 and 5 |
| 3. Open an incident, read the investigation and review a narrowly scoped proposed action | Scene 6, then the SRE guide |

**Say:** "An engineer who can read the evidence is not necessarily an approver.
Reader and approver are separate roles, and nothing on this Arc path approves or
changes anything."

{{CompanionSection}}

Leave the lab unchanged. Parking is a separate operator action, with the companion
parked first if present; retained services and storage still cost money.

## Fallback queries

Use these only when a workbook tile is empty or someone asks. They read the same
workspace as the workbooks. Paste one at a time in **Logs** and use the stated time
range.

### Last 24 hours: CPU by host

```kusto
Perf
| where TimeGenerated > ago(24h)
| where tolower(_ResourceId) startswith "{{ArcScope}}/providers/microsoft.hybridcompute/machines/"
| where CounterName has "Processor Time" and InstanceName in ("_Total", "total")
| summarize AverageCPU=avg(CounterValue), PeakCPU=max(CounterValue) by Computer
| order by PeakCPU desc
```

Idle CPU is not a sizing benchmark.

### Last 7 days: configuration changes

```kusto
ConfigurationChange
| where TimeGenerated > ago(7d)
| where tolower(_ResourceId) startswith "{{ArcScope}}/providers/microsoft.hybridcompute/machines/"
| summarize Changes=count(), LastChange=max(TimeGenerated) by Computer, ConfigChangeType
| order by LastChange desc
```

No changes in the window can be normal; do not generate fake changes.

### Last 24 hours: Linux activity

```kusto
Syslog
| where TimeGenerated > ago(24h)
| where tolower(_ResourceId) startswith "{{ArcScope}}/providers/microsoft.hybridcompute/machines/"
| summarize Events=count(), LastSeen=max(TimeGenerated) by Computer, Facility, SeverityLevel
| order by LastSeen desc
```

Linux dependency mapping is intentionally disabled in this lab.

### Last 7 days: recorded SQL incident rows

```kusto
Event
| where TimeGenerated > ago(7d)
{{SqlHostFilter}}
| where Source =~ "ArcSqlEngineDemo" and EventID in (6201, 6001)
| project TimeGenerated, Computer, EventID, EventLevelName, RenderedDescription
| order by TimeGenerated desc
```

These rows are dated history. The lock self-recovers in about 12 seconds, so
explain historical SQL wait evidence, not a currently blocked orders worker or an
SRE-performed remediation.

## Operator notes

These notes are for the operator who prepares and hands over this page. They are
not presenter patter, and nothing here is run during the presentation.

- **Before handing over:** verify Active readiness independently
  (`Test-ArcDemoReadiness.ps1 -DesiredState Active`, read-only with a bounded
  timeout) and poll until any telemetry-only lag clears to a pass; lag is not a
  ready handoff. Open every link on this page once. Check the nested guest with
  `Test-ArcSqlDemoInventory.ps1` (read-only).
- **Nested guest:** its lifecycle follows the `nestedSqlGuest` block in the private
  skin. The presenter never starts, stops or repairs it; a guest that is parked or
  still starting is "not available in this run", never claimed. The Azure parent
  that hosts it is disclosed as lab implementation detail.
- **Extension states:** the Extensions page of an Arc machine shows lab artifacts
  (Linux Azure Monitor Agent and Change Tracking come through the Azure VM
  extension path; patch and Defender extensions may show Creating, Updating or
  Failed while assessments and telemetry still work). Do not delete stuck Arc
  extensions, change AV mode or policy, reinstall or restart anything to tidy it.
- **SQL incident:** a navigation-only rehearsal uses the dated threads. A fresh run
  needs a fresh alert route first (SRE repo: `Invoke-SreDemoRoute.ps1 -Action
  Prepare`, then `-Action Restore` afterwards) or the agent merges the new alert
  into the earlier thread. It uses only the Arc-owned bounded lock-timeout helper
  and the exact-host Sev2 alert, preserves the orders worker, needs its own
  approval, runs sequentially with any LOB scenario and is never run as readiness
  or lifecycle preparation. An alert that remains Fired is not proof of a current
  block.
- **LOB incident:** the degraded state is run in the SRE half under its own
  approval and the same fresh alert route; it is never a step on this Arc path and
  never part of navigation-only rehearsal. Starting the application, changing
  collection or injecting a fault is not done to make a tile or a query green.
- **Workbooks:** they read existing telemetry only. Do not change collection,
  induce load or activate hosts to populate a tile; history is thin when the lab
  runs on demand, and the page says so.
- **Reader and approver:** on this Arc path the presenter only reads evidence: do
  not approve a Review card or accept a request for additional permissions here.
  The Review approval belongs to the SRE half.
- **SRE hand-over:** the companion guide owns the investigation, the human Review
  approval and any separate approval to send an investigation or trigger an
  incident. Arc-only activation never prompts for or induces an incident.

## Navigation references

Portal names can change; links identify resources but do not grant access.
The resource links use the same portal format printed by repo deployment.
No new portal UI rehearsal or current health is asserted by generating this file.
Navigation is grounded in [Workbooks](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-overview),
[workspace Logs](https://learn.microsoft.com/azure/azure-monitor/logs/log-analytics-tutorial),
[KQL mode](https://learn.microsoft.com/azure/azure-monitor/logs/log-analytics-simple-mode#switch-modes),
[the Azure Arc Machines list](https://learn.microsoft.com/azure/azure-arc/servers/private-link-security#connect-to-an-azure-arc-enabled-server),
[alert rules](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-manage-alert-rules)
and [Update Manager](https://learn.microsoft.com/azure/update-manager/manage-multiple-machines).
The support boundaries are grounded in
[SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/overview?view=sql-server-ver17)
(license types and unsupported configurations),
[SQL Server inventory](https://learn.microsoft.com/sql/sql-server/azure-arc/view-inventory?view=sql-server-ver17),
[evaluating Arc-enabled servers on an Azure VM](https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine)
and [Azure Monitor Agent environments](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-supported-operating-systems#on-premises-and-in-other-clouds).
