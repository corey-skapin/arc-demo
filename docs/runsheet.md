# Arc: from servers to an operational view

**Presenter:** open the generated `.local/presenter-runsheet.md` and follow this
page from top to bottom. Its links and queries are already filled in. This tracked
file is the source template, not a second presentation.

Context recorded **{{RecordedAtUtc}}**; document generated **{{GeneratedAtUtc}}**.
Generation is offline, not a fresh readiness or application-health check.
The preparing operator verifies readiness before handing over this page.

Allow **20-30 minutes**. Everything below is read-only: do not start machines,
run assessments, change configuration, send test emails or induce a fault.

## 1. Start with the estate (3 minutes)

Open [the estate workbook]({{workbookUrl}}).

**Say:** "We want one operational view of servers outside Azure: what is
connected, how it is performing, what changed, and what needs attention."

Show **Estate connectivity (last 15m)**, **Hosts beating over time (24h)**,
and **Per-host CPU utilisation (24h)**. Point to a real reporting host and its
timestamp. Gaps after parking are expected; they are not continuous uptime.
If a tile is empty, the scoped queries below are the fallback.

This lab simulates on-premises servers using Azure VMs and `MSFT_ARC_TEST=true`.
It is a demo, not a hardened production architecture or blanket feature validation.

## 2. Show what Arc adds (2 minutes)

Open [the Windows Arc machine]({{windowsMachineUrl}}), **{{windowsMachineName}}**.
Show its connection state, operating system and tags. Then open
[the Linux Arc machine]({{linuxMachineUrl}}), **{{linuxMachineName}}**.

**Say:** "Arc gives each server an Azure resource identity without making it an
Azure VM. That identity lets us apply monitoring and governance consistently."

These are Arc resources, not the lab's backing VMs. Tags describe intent; they
do not prove compliance, active antivirus or a purchased licence.

## 3. Prove telemetry is fresh (4 minutes)

Open [the workspace]({{workspaceUrl}}), **{{workspaceName}}**, and select **Logs**.
If needed, switch **Simple mode** to **KQL mode**. Paste one query at a time,
select **Run**, and use the time range stated beside it.

**Last 10 minutes: who is reporting right now?**

```kusto
Heartbeat
| where TimeGenerated > ago(10m)
| where tolower(_ResourceId) startswith "{{ArcScope}}/providers/microsoft.hybridcompute/machines/"
| summarize LastHeartbeat=max(TimeGenerated) by Computer, OSType
| order by Computer asc
```

Missing hosts are missing evidence, not zero-valued success. The separate
operator readiness check compares exact expected identities.

**Last 24 hours: show CPU rather than an average of unrelated counters.**

```kusto
Perf
| where TimeGenerated > ago(24h)
| where tolower(_ResourceId) startswith "{{ArcScope}}/providers/microsoft.hybridcompute/machines/"
| where CounterName has "Processor Time" and InstanceName in ("_Total", "total")
| summarize AverageCPU=avg(CounterValue), PeakCPU=max(CounterValue) by Computer
| order by PeakCPU desc
```

**Say:** "We can go from the estate view to timestamped evidence without logging
into each server." Idle CPU is not a sizing benchmark.

## 4. Show change and Linux signals (3 minutes)

Stay in the same workspace. Select **Last 7 days** for change records:

```kusto
ConfigurationChange
| where TimeGenerated > ago(7d)
| where tolower(_ResourceId) startswith "{{ArcScope}}/providers/microsoft.hybridcompute/machines/"
| summarize Changes=count(), LastChange=max(TimeGenerated) by Computer, ConfigChangeType
| order by LastChange desc
```

Then select **Last 24 hours** for Linux activity:

```kusto
Syslog
| where TimeGenerated > ago(24h)
| where tolower(_ResourceId) startswith "{{ArcScope}}/providers/microsoft.hybridcompute/machines/"
| summarize Events=count(), LastSeen=max(TimeGenerated) by Computer, Facility, SeverityLevel
| order by LastSeen desc
```

**Say:** "The same workspace carries operating-system evidence across Windows
and Linux." No changes in the window can be normal; do not generate fake changes.
Linux dependency mapping is intentionally disabled in this lab.

## 5. Show the business application (3 minutes, when prepared)

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

**Say:** "This is the healthy business worker processing transactions, not just
an agent heartbeat. Its events include the deployed source reference."

Expect a fresh Information event roughly every minute with the default worker
settings. If there are no rows, state the gap and skip this beat; do not show
October's fault as today's activity. Healthy event collection requires the
source-specific DCR selector. Starting the app, changing collection or injecting
a fault is operator preparation under separate approval, never a presenter step.

## 6. Turn evidence into an alert (3 minutes)

Open [the missing-heartbeat alert rule]({{heartbeatAlertUrl}}),
**{{heartbeatAlertName}}**. Show its scope, condition, severity and evaluation
window. Then open [the action group]({{actionGroupUrl}}),
**{{actionGroupName}}**, to show the configured notification route without
exposing the recipient or selecting **Test**.

**Say:** "We turn signals into a routed operational action. Email is configured
here; an integration or delivered notification needs its own evidence."

The demo rule evaluates observed Heartbeat rows, not a complete never-seen-host
inventory. Do not promise complete outage detection or a fixed notification time.
If existing alert history is populated, show the affected resource and timestamp.
A healthy lab may have no fired alerts: show the rule, not a manufactured outage.

## 7. Finish with operating posture (3-5 minutes)

Return to [the Windows Arc machine]({{windowsMachineUrl}}).
Show its available **Updates** assessment/status view; point to **Last assessed**
and actual missing-update rows, not just an enabled extension.

**Say:** "Visibility comes before a planned change. We can see update and
configuration posture centrally, then agree the action and maintenance window."

If there is no assessment data, say so and move on; do not select **Check for
updates**, install updates or alter schedules. Policy assignment is not evaluated
compliance. Monitor readiness is not active AV, full EDR, patch completion or
application proof. SQL Server/Arc SQL/BPA is not part of this default demo.

## 8. Close or hand over

Return to [the workbook]({{workbookUrl}}).

**Say:** "Arc provides the identity. Monitor provides evidence and alerts.
We can operate the existing estate before adding automated investigation."

{{CompanionSection}}

Leave the lab unchanged. Parking is a separate operator action, with the
companion parked first if present; retained services and storage still cost money.

## Navigation references

Portal names can change; links identify resources but do not grant access.
The resource links use the same portal format printed by repo deployment.
No new portal UI rehearsal or current health is asserted by generating this file.
Navigation is grounded in [Workbooks](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-overview),
[workspace Logs](https://learn.microsoft.com/azure/azure-monitor/logs/log-analytics-tutorial),
[KQL mode](https://learn.microsoft.com/azure/azure-monitor/logs/log-analytics-simple-mode#switch-modes),
[alert rules](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-manage-alert-rules)
and [Update Manager](https://learn.microsoft.com/azure/update-manager/manage-multiple-machines).
