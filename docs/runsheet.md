# Arc/Monitor presenter guide

The canonical first-time-presenter walkthrough for this repository. Start with
[the documentation index](README.md) if you are unsure what to read.
**Read-only by default:** no deployment, activation, guest commands, fault
injection, alert tests, email sends, patch scans or remediation during this tour.

Plan **20-30 minutes** including discussion and selected posture beats. The
core workbook -> telemetry -> alert -> Arc identity story takes 12-15 minutes.
The lab operator prepares the estate separately using [runbook.md](runbook.md)
and [lifecycle.md](lifecycle.md); these are not additional presenter scripts.

## Before you start

### Understand what you are showing

"We have servers outside Azure and want one operational view of inventory,
performance, change, patch/security posture and alerts. Arc supplies the resource
identity; Azure Monitor supplies the evidence and alerting. Investigation can
then continue into an optional SRE Agent."

This is an Azure-hosted **simulation** of on-premises servers, using
`MSFT_ARC_TEST=true`. Default fleet: five Windows Server 2016/2019/2022 hosts and
three Ubuntu 22.04 hosts. Backing Azure VMs are in a separate infrastructure
group; Arc identities and monitoring are in the presentation group. Explain
the simulation honestly rather than hiding it if asked.

No SQL Server engine, Arc SQL/BPA, native comparison VM, AKS or SRE is required.
A SQL-capable hostname is not a database. A mixed-legacy fixture may include
represented-not-running entries; never count them as connected live machines.
See [support boundaries](lifecycle.md#linux-monitoring-and-support-stance).

### Obtain a private input card from the operator

Fill this in outside git before rehearsal. Examples below use synthetic/default
names: substitute the actual retained skin/prefix, not a new public example skin.

| Input | Default/example / what to obtain |
|---|---|
| Tenant, subscription, private skin/fleet | Confirmed runtime IDs, exact private paths and any retained overrides; never infer these from CLI defaults. |
| Presentation / infrastructure groups | `rg-arc-demo` / `rg-arc-demo-infra`. |
| Log Analytics workspace | `law-arc-demo` in the presentation group, not a subscription governance workspace. |
| Saved workbook | Skin `labels.workbookDisplayName`, normally `Arc Demo - Estate Overview` (dash typography can differ). Search `Estate Overview`; do not pick a gallery template. |
| Arc Windows / Linux example | `win-app-01` / `lnx-app-01`, or actual operator-selected monitored hosts. |
| Heartbeat rule / action group | `alert-arc-demo-host-missing-heartbeat` / `ag-arc-demo`. Keep the actual notification recipient private. |
| Optional policy assignments | `mcsb-arc-demo` / `nist-arc-demo`; display names normally **Microsoft cloud security benchmark (Arc Demo)** / **NIST SP 800-53 Rev. 5 (Arc Demo)**. Confirm the actual retained assignments. |
| Optional app / restart rule | Only if retained: `ca-arc-demo-fault` / `alert-arc-demo-containerapp-restarts` in the infrastructure group. |
| Evidence and access | Latest dated Ready JSON, successful activation result if waking was needed, known gaps; approved historical alert/incident and timestamps, if any. |
| Optional SRE handoff | Companion repository location, its canonical `docs\delivery-runsheet.md`, actual agent URL and approved existing incident. |

The presenter needs already-granted read access to the chosen resources,
workbooks, logs and alert history. A workbook can open while its underlying data
queries are denied: verify both. Monitoring Reader and Log Analytics Reader are
relevant built-in roles; security views need the appropriate existing security
read access too. Deployment Owner/UAA rights are **not** a prerequisite for
presenting. Ask the operator to resolve access before the meeting; do not grant
roles, consent, change accounts or troubleshoot authentication live.

## Prepare and practise once

Allow at least a 30-45 minute preparation window after an operator-approved wake,
and longer if assessment/policy/inventory data is missing. Time alone does not
make the lab ready. A parked lab needs the operator's separately approved
lifecycle procedure, not a presenter improvising VM starts.

1. Open <https://portal.azure.com> in the already-authorized browser profile.
   Confirm the operator's tenant and subscription. Use portal resource/search
   filters to stay within that subscription and the two demo groups.
2. Have the operator supply fresh Ready evidence, or run this **read-only**
   command locally with the actual private inputs and existing Azure sign-in:

   ```powershell
   .\scripts\Test-ArcDemoReadiness.ps1 `
     -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
     -SkinPath <PRIVATE_SKIN_PATH> `
     -DesiredState Ready -OutputFormat Json -TimeoutSeconds 600
   $LASTEXITCODE
   ```

   Exit 0 means required Monitor/infrastructure checks pass; 1 means failure,
   2 means still pending. Keep the timestamp and expected-ID results privately.
   A prior 79/79 snapshot is not today's guarantee; check count varies with
   retained workloads. This does not certify patch completion, policy scores,
   every workbook query, guest applications or active endpoint protection.
   Do not rerun activation just to refresh this evidence.
3. Open/bookmark the workbook, workspace Logs, chosen Arc machine, Monitor
   Alerts/Alert rules/Action groups and any selected posture pages using the
   steps below. Confirm data access and resource identity before bookmarking.
4. Run each chosen query once. Record one actual host, one CPU row, one CT or
   syslog row, and an existing alert timestamp if available. If there is no
   alert history, rehearse the **rule-only** fallback; do not create an incident.
5. Practise the flow below once with a timer. Say each quoted line, point to
   the specified visible result, then move on. Budget at most 60 seconds for
   a missing optional tile before using its fallback. If workbook/log access
   or required readiness is broken, stop and ask the operator to investigate;
   do not label an evidence-only or partial tour fully live.
6. Record which optional posture/scenario beats you will omit. For a combined
   demo, rehearse the handoff with the SRE presenter rather than repeating Arc.
   Store private screenshots/evidence securely; use only sanitized, explicitly
   dated historical evidence as a fallback, never as a live screen.

Activation normally checks all retained guests and submits asynchronous patch
assessments **on each run unless explicitly skipped**, including retries against
running hosts. Submission is not assessment completion. Linux rows can lag;
Windows assessment rows were the more reliable observed proof point. CT cycles
and policy evaluation may take longer still. Do not reinstall agents, trigger
scans or change security policy to improve a presentation.

## Present the Arc/Monitor demo

### 1. Lead with the estate workbook (3 minutes)

**Go:** Portal search -> **Monitor** -> **Workbooks**. In the gallery, select
the **Workbooks** tab and search for the saved title on your input card.
If necessary use **Browse across galleries**. Select the saved workbook for
the intended subscription/group. An operator-provided workbook link from the
deployment is another starting point. Do not select **New**, a public template
or **Edit**. [Microsoft's current workbook navigation][workbooks].

**Show:** In the custom Estate Overview workbook, point to these source-defined
tiles in order: **Estate connectivity (last 15m)**,
**Hosts beating over time (24h)**, **Per-host CPU utilisation (24h)**,
**Configuration changes (24h)**, **Top 25 applications across the estate**.
Scroll to a populated tile rather than promising every tile contains data.
Later tiles include tagging hygiene, Windows errors and Linux syslog activity.

**Expect:** Recent Windows/Linux connectivity and historical telemetry for the
operator's expected fleet. Deallocation gaps in the 24-hour chart are normal
after hibernation; they are not continuous customer uptime. These summary tiles
group by computer name and can omit wholly silent hosts; exact-ID readiness is
the separate gate, not an eight-host bar chart.

**Say:** "Start with what the platform team needs: which servers are reporting,
how they are performing, and what changed. This is evidence from the estate,
not a server-by-server login exercise."

**Fallback:** Verify the selected workbook/workspace and read access. If a tile
is empty, use the corresponding workspace query in step 2. If the whole workbook
is unavailable, show only the working logs and disclose the missing dashboard.
Do not claim this custom workbook has policy/compliance tiles: it does not.

### 2. Diagnose with scoped logs (4 minutes)

**Go:** Portal search -> **Log Analytics workspaces** -> the input-card
workspace -> **Logs**. Check the workspace name/scope before running anything.
If the editor opens in **Simple mode**, choose **KQL mode** from the top-right
mode dropdown. Use a new query tab, paste **one** query, select **Run**, and
read its **Results**. Use a matching time range (24 hours for these examples;
7 days for the CT query). [Mode switch][logs-mode], [query interface][logs].

Replace `rg-arc-demo` in all queries if using a different presentation group.
These queries are read-only presenter aids, not replacements for the exact-ID
readiness checks. Query errors and empty results are different conditions.

**Show A - freshness and identity:**

```kql
Heartbeat
| where TimeGenerated > ago(10m)
| where _ResourceId contains "/resourceGroups/rg-arc-demo/"
| summarize LastHeartbeat=max(TimeGenerated) by ResourceId=tolower(_ResourceId), Computer, OSType
| order by Computer asc
```

**Expect:** Recent timestamps and the **Arc** resource IDs in the presentation
group for each monitored host; compare with the private expected list. A host
missing from this query has no fresh matching row, not a zero-valued success.

**Show B - Windows CPU, not an average of unrelated perf counters:**

```kql
Perf
| where TimeGenerated > ago(24h)
| where _ResourceId contains "/resourceGroups/rg-arc-demo/"
| where CounterName has "Processor Time" and InstanceName in ("_Total", "total")
| summarize AvgCPU=avg(CounterValue), MaxCPU=max(CounterValue), P95=percentile(CounterValue, 95) by Computer
| order by P95 desc
```

**Expect:** CPU percentage rows for reporting hosts. Do not call missing Linux
rows a sensor failure or use idle samples as a cold-start/patch/SQL sizing
benchmark. These counters demonstrated Windows utilization in the reviewed lab.

**Show C - pick one actual change/inventory or Linux signal:**

```kql
ConfigurationChange
| where TimeGenerated > ago(7d)
| where _ResourceId contains "/resourceGroups/rg-arc-demo/"
| summarize Changes=count(), LastChange=max(TimeGenerated) by Computer, ConfigChangeType
| order by LastChange desc
```

```kql
Syslog
| where TimeGenerated > ago(24h)
| where _ResourceId contains "/resourceGroups/rg-arc-demo/"
| summarize Events=count(), LastSeen=max(TimeGenerated) by Computer, Facility, SeverityLevel
| order by LastSeen desc
```

**Say:** "Fresh heartbeat establishes who is reporting. Performance and change
records narrow a hypothesis. Logs, Arc connection and endpoint security are
different checks; none of these alone proves an application is healthy."

**Fallback:** Confirm workspace, time range and permission. No CT changes can
mean no observed changes or an incomplete collection cycle; show a rehearsed
populated syslog/CPU result and state the gap. No fresh Heartbeat means stop
calling that host live-ready. Never manufacture change/error records.

### 3. Connect diagnosis to an alert and routing (3 minutes)

**Go:** Portal search -> **Monitor** -> **Alerts** -> **Alert rules**.
Filter to the target subscription and presentation group; select the named
heartbeat rule on your input card. Read its existing scope, condition, severity,
evaluation/window and associated action group without editing.
[Rule navigation][rules].

**Show:** The workspace-scoped heartbeat rule, severity 2, five-minute
evaluation, 15-minute window and >10-minute stale-heartbeat query.
It evaluates observed `Heartbeat` rows grouped by computer, not a complete
expected-inventory anti-join. A never-seen host or one absent beyond the query
window may not appear: do not promise complete outage detection or a fixed
ten-minute notification. This is the configured demo rule, not a production
monitoring design.

From **Monitor** -> **Alerts**, select **Action groups**, then the named group.
Inspect the configured **email** notification without exposing its address.
Do not select **Test**, create/edit receivers or send a test notification.
Configuration is not delivery proof: current Microsoft guidance also describes
recipient verification requirements. Use only operator-provided dated delivery
evidence if claiming an email was received. [Action groups][actions].

For previous events, return to **Alerts**, set the subscription/group/time
filters to an existing operator-approved occurrence and select its row for
**Alert details**. Alternatively open the rule's **History**.
Read fired/resolved condition, affected resource and timestamp; do not
acknowledge/close it. [Instances][instances], [rule history][rules].

**Say:** "The signal becomes an actionable alert. Email is the deployed baseline;
an action group can integrate with other systems, but this repo does not deploy
a Logic Apps, ServiceNow or PagerDuty workflow. An optional SRE layer can
investigate these alerts under its own configuration and approval model."

**Fallback:** A healthy lab can have no current alerts. Show the rule and routing,
say "configured, not a live firing or delivery test", and move on. If retained,
the optional Container App restart rule is in the **infrastructure** group:
switch the group filter, inspect its existing rule/history, and identify its
metric rather than calling it a heartbeat log alert. No break/reset is needed.

### 4. Reveal the Arc identity and inventory (2 minutes)

**Go:** Portal search -> **Azure Arc** -> **Machines**; filter to the target
subscription and presentation group. The portal home can also expose
**Machines - Azure Arc**. Select the input-card Windows machine.
If the hub layout differs, use portal resource search to find that exact
machine and confirm its group and type **Machine - Azure Arc** /
`Microsoft.HybridCompute/machines`, not its backing Azure VM.

**Show:** Connection state, OS information and tags on the Arc resource. Point
out `osTier` and `monitorTier` where present. Tags such as `defender=plan2`,
`machineConfig=enabled` and `esuEligible` express configuration/story metadata,
not proof of working security, a TLS assignment or purchased ESU.

**Say:** "This is the Azure resource identity that makes a non-Azure server
addressable by governance and operations. It is distinct from this lab's backing
Azure VM. We did not start with RDP."

**Fallback:** Use the following inventory query rather than guessing an
**Inventory** blade in the Arc hub. Portal search **Resource Graph Explorer**,
use **Directory** to scope to the confirmed subscription, paste the query into
**Query 1**, select **Run query**, then **Results**. [Resource Graph][arg].

```kql
resources
| where type =~ "microsoft.hybridcompute/machines"
| where resourceGroup =~ "rg-arc-demo"
| project name, osTier=tostring(tags.osTier), monitorTier=tostring(tags.monitorTier), status=tostring(properties.status)
| order by name asc
```

Do not save/pin the query during presentation. Reader visibility can change
returned inventory; compare against the operator's expected resource list.

### 5. Choose posture beats for the full tour (6-10 minutes)

These screens are **optional evidence beats**, not prerequisites for the
12-15 minute core. Rehearse the ones with useful current data. Follow the linked
current Microsoft pages if tenant layout differs; do not improvise a legacy
menu path or enable a feature to populate a page.

| Beat and time | Go / select / show | Expected evidence, talk track and honest fallback |
|---|---|---|
| Updates, 3 min | Portal search **Azure Update Manager** -> **Machines**. Filter subscription/group to Arc resources; select the rehearsed Windows machine for its existing assessment details/history. | Show **Last assessed time** and actual missing-update/status rows. "Central visibility before an agreed patch window." Assessment submission is not completion or installed updates. If **No updates data**, show that state and explain the gap; do not select **Check for updates**, **Assess now**, **One-time update** or change schedules. [Current status/history navigation][updates]. |
| Security, 3 min | Portal search **Defender for Cloud** -> **Recommendations**. Scope to the target lab; select one rehearsed recommendation whose affected asset is a demo machine. Read **Overview** and **Remediation steps**, without applying them. | Show the actual finding, affected asset and recommendation. "Shared posture, not a claim the server is secure." Do not promise a specific CVE, score, attack path or paid CSPM feature. Flat/resource/title grouping and grouped-to-individual preview findings vary. If no lab finding is visible, omit the drill-down rather than showing another customer's resource. [Current Azure-portal experience][security]. |
| Governance, 2 min | Portal search **Policy** -> **Compliance**; set **Scope** to the confirmed subscription and select the actual demo MCSB/NIST initiative assignment from the input card. | Show evaluated compliance details only if populated. "Assigned policy and evaluated compliance are different." A tag is not a TLS 1.2 policy test. No data: **Policy** -> **Assignments**, same scope, named assignment, is configuration-only evidence; do not request a scan or remediate. [Compliance navigation and evaluation timing][policy]. |
| Legacy/ESU discussion, 1 min | Return to the Arc resource's actual OS/tags or rehearsed inventory results. | Default fleet starts at WS2016. Discuss older OS only as a support-gated customer follow-on; no represented WS2008/2012 placeholder is a running host and no ESU entitlement is bought by this repo. [Fleet reference](legacy-os-fleet.md). |

For the security beat, preserve the inspected Linux limitation: sensors reported
healthy/licensed **in passive mode**, real-time protection disabled, with
extension/direct-health event-provider discrepancies. Monitor PASS,
onboarding or subscription Plan 2 configuration is not active AV/full EDR proof.
Windows endpoint proof also needs its own evidence. Do not change AV policy.

Windows VM Insights dependency maps are an additional rehearsed-only surface,
not required for this tour. Linux dependency mapping is intentionally disabled.
Use the already-demonstrated CPU/CT/syslog data if a map is absent; never install
a Dependency Agent mid-demo. SQL/Arc SQL/BPA is not an optional portal shortcut:
see [the SQL support decision](sql-arc-spike.md).

## Optional SRE handoff

At the end of step 3 (or after the Arc tour), keep the selected alert/rule open.
State its resource, signal, severity and timestamp. If there is no historical
alert, say that explicitly: the next segment may only use its own preexisting
incident evidence, not imply a newly detected outage.

Open the companion repository supplied by the operator and continue its
`docs\delivery-runsheet.md` **after the Arc/Monitor segment**, using its private
agent URL and approved existing incident. The companion `docs\README.md` chooses
the SRE presenter path and optional scenarios. Do not guess an **Investigate**
button, send a new agent prompt, approve a repair or induce a fault as part of
this read-only handoff. Review mode and a configured handler are not proof an
automated repair executed; the SRE guide owns that evidence/approval distinction.

Container App, AKS, native-VM and SQL-shaped scenarios are opt-ins, not extra
default prerequisites. Their operator instructions remain in
[container-app-fault.md](container-app-fault.md),
[aks-break-scenario.md](aks-break-scenario.md) and
[sql-workload-simulation.md](sql-workload-simulation.md). Live break/reset
requires a separate agreed owner, approval, deadline and verified fallback
recovery; none is authorized by reading or rehearsing this guide.

## Close and hand back

"Arc provides identity and governance; Monitor provides telemetry and alerts.
We can start with the existing estate and add investigation without pretending
this demo lab is a hardened production architecture."

Finish on the workbook. Hand the lab back to its operator unchanged.
If parking is requested separately, park the companion SRE layer first, then
Arc, following [lifecycle.md](lifecycle.md). Wake in the reverse dependency
order. Nightly VM shutdown is not whole-stack hibernation. Data/disks/services
still cost money while parked; see [cost.md](cost.md).
Retained HDD is a deliberate existing-lab choice, not a new saving or a default
for new OS disks; SSD remains the fresh default and HDD OS support retires
8 September 2028. Do not convert tiers during a demo.

## Portal grounding and observation limits

**Documentation checked 21 October 2026.** The links below are the current
Microsoft Learn pages retrieved during this review, not old video click paths.
Portal home was inspected read-only in an authenticated lab: global search,
**Azure Update Manager**, **Azure Arc**, **Machines - Azure Arc**, and the
workspace resource link were visible. The workspace page did not render
reliably after navigation; a stale accessibility tree was not treated as blade
verification. No fresh end-to-end workbook/Logs/alert/posture UI rehearsal or
new runtime readiness test is claimed by this documentation-only review.

Thus steps 1-3 and the posture blade details are **Microsoft-documented, not
locally UI-verified** in this pass. Workbook tile names, alert settings and
workload defaults were checked against repo source. Earlier operational
readiness/activation evidence is described in [lifecycle.md](lifecycle.md),
not evidence that every portal pane is currently populated. Rehearse and retain
actual bookmarks before presenting. If a documented surface is absent, use the
specified query/rule-only fallback or omit the beat; do not invent new labels.

| Surface | Authoritative grounding / why it matters |
|---|---|
| Saved workbook, permissions and gallery | [Azure Workbooks][workbooks]; avoids assuming a resource-group **Workbooks** blade or selecting a template. |
| Logs entry, query scope and Simple/KQL switch | [Log Analytics tutorial][logs], [current mode selector][logs-mode]; queries must use the intended workspace. |
| Scoped resource inventory | [Resource Graph portal quickstart][arg]; **Directory**, **Query 1**, **Run query**, **Results**. |
| Alert rule/history and instance details | [Manage rules][rules], [manage instances][instances]; existing configuration differs from an actual firing. |
| Email versus optional automation | [Action groups][actions]; read receiver configuration, do not send tests or assume delivery/verification. |
| Assessment rows/history | [Update Manager status][updates]; asynchronous assessment and missing-data states differ from patch installation. |
| Current security view | [Review recommendations, Azure portal pivot][security]; grouping/preview can vary, avoid legacy fixed CVE drill-down claims. |
| Compliance scope/timing | [Get policy compliance data][policy]; evaluation has no guaranteed completion deadline. |

[workbooks]: https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-overview
[logs]: https://learn.microsoft.com/azure/azure-monitor/logs/log-analytics-tutorial
[logs-mode]: https://learn.microsoft.com/azure/azure-monitor/logs/log-analytics-simple-mode#switch-modes
[arg]: https://learn.microsoft.com/azure/governance/resource-graph/first-query-portal
[rules]: https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-manage-alert-rules
[instances]: https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-manage-alert-instances
[actions]: https://learn.microsoft.com/azure/azure-monitor/alerts/action-groups
[updates]: https://learn.microsoft.com/azure/update-manager/manage-multiple-machines
[security]: https://learn.microsoft.com/azure/defender-for-cloud/review-security-recommendations
[policy]: https://learn.microsoft.com/azure/governance/policy/how-to/get-compliance-data
