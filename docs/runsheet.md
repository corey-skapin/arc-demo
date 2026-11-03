# Arc: from servers to an operational view

**Presenter:** open the generated `.local/presenter-runsheet.md` (Arc only) or, to run the
whole demo from one page, `.local/full-demo-runsheet.md` (this guide, then the SRE half,
then one close), and follow it from top to bottom. Its links and queries are already
filled in. This tracked file is the source template, not a second presentation.

Context recorded **{{RecordedAtUtc}}**; document generated **{{GeneratedAtUtc}}**.
Generation is offline, not a fresh readiness or application-health check.
The preparing operator verifies readiness before handing over this page.

## The story in one minute

Every infrastructure lead gets the same questions on a Monday morning: how many
servers do we really run, are they safe, do we have room for the next project,
where is the money going, and who is looking when something breaks at 2 a.m.? This
guide answers them one at a time, from one view, with the gaps showing as gaps.

One thread runs through it: **follow one database**, the orders database. We meet it
in the estate list, look inside its server, see what Azure Arc and Azure Monitor each
know about it, ask whether its hosts have room and whether they are worth their
cost, and end at the alert rule that starts the night shift. Keep coming back to it;
it is what makes this a story and not a tour of tiles.

Five acts: **understand** (chapters 1 to 4), **plan** (chapter 5), **prioritise**
(chapter 6), **operate** (chapter 7, then the SRE guide) and **close**.

| # | Chapter | The customer's question | Pain points | Evidence |
| --- | --- | --- | --- | --- |
| Opening | The Monday-morning questions | "Three questions land on my desk every Monday." | All | Read aloud |
| 1 | What do we actually have? | "How many servers do we run, and which can I trust the data on?" | 1 Resource visibility | Live |
| 2 | Show me one server | "Can an engineer understand a Windows server and a Linux server the same way, without logging in?" | 2 Infrastructure complexity, 5 Training and skills | Live |
| 3 | Are we safe and up to date? | "If an auditor asked, could we answer today, and prove it?" | 1 Resource visibility, 7 Operational efficiency | Live |
| 4 | What about the database? | "My databases matter most. What do we actually know about them?" | 2 Infrastructure complexity, 6 Migration and modernisation | Live; nested Arc SQL is experimental; incident rows are dated |
| 5 | Do we have room for what is next? | "A new project wants capacity. Do we have it, and how sure are we?" | 3 Capacity planning | Live |
| 6 | Where is the money going? | "What are we paying for and not using, and how do I know before I switch anything off?" | 8 Cost optimisation, 6 Migration and modernisation | Live |
| 7 | What happens at 2 a.m.? | "When it breaks at night, how long before someone with the right context is looking?" | 7 Operational efficiency | Alert rules live; incidents live or dated in the SRE half |
| Close | The Monday answers | "So what do we do next?" | All; 4 and 6 have prepared answers | Recap |

Pain point 4 (disaster recovery) is out of scope and pain point 6 (migration and
modernisation) is evidence only. Prepared answers for both are in
[prepared answers](#prepared-answers), so you are not caught out.

The three engineer tasks (pain point 5) are woven through it. Say them when they
come up; none needs a terminal, a subscription ID or hand-written queries.

| Engineer task | Where |
| --- | --- |
| 1. Find a server or workload and see whether its data is current | Chapters 1 and 2 |
| 2. Open the capacity or optimisation view and drill into the evidence | Chapters 5 and 6 |
| 3. Open an incident, read the investigation and review a narrowly scoped proposed action | Chapter 7, then the SRE guide |

**Live** means the page reads current Azure data when you open it. **Recorded**
means dated evidence from an earlier approved run: say its date and never present
it as happening now. Anything that needs a command is in the
[operator notes](#operator-notes) at the end, not in what you say.

## Timing and cut lists

Allow **25-28 minutes** for the full path: the chapter times below add up to 25,
and the four audience questions take about three more. The SRE guide it hands over
to has its own timing. If you are more than a minute behind at any clock time in a
chapter heading, use a cut list.

| # | Chapter | Full | 20-minute | 15-minute |
| --- | --- | --- | --- | --- |
| Opening | The Monday-morning questions | 1 | 1 | 1 |
| 1 | What do we actually have? | 3 | 2 | 2 |
| 2 | Show me one server | 4 | 3 | 3 |
| 3 | Are we safe and up to date? | 3 | 2 | 0 |
| 4 | What about the database? | 3 | 2 | 0 |
| 5 | Do we have room for what is next? | 3 | 3 | 3 |
| 6 | Where is the money going? | 3 | 2 | 2 |
| 7 | What happens at 2 a.m.? | 3 | 2 | 2 |
| Close | The Monday answers | 2 | 1 | 1 |

The 20-minute version is 18 minutes of content and the 15-minute version is 14,
each plus its conversation. What to drop:

- **20 minutes:** in chapter 1 show the tiles and one row, and skip Asset Inventory.
  In chapter 2 use the SQL host and the Linux host, and say the data collection rule
  in one sentence instead of opening it. In chapter 3 show **Policy compliance** and
  the table of pending updates only. In chapter 4 show **SQL at a glance** and **Lock
  timeouts and recoveries** only. In chapter 6 show the summary tiles and
  one review card. In chapter 7 show the missing-heartbeat rule and the SQL rule. In
  the close, read the table only.
- **15 minutes:** everything above, and skip chapters 3 and 4 entirely (say in the
  close that posture and SQL are the next conversation), and open no data collection
  rule in chapter 2.

## Ground rules

- **Read-only.** Everything on this Arc path is read-only: do not start machines, run
  assessments, select **Check for updates**, change configuration, send test emails,
  approve anything or induce a fault here. Live faults, fresh investigations and the
  Review approval belong to the SRE half, with their own approvals.
- **Honest frame.** This lab simulates on-premises servers using Azure VMs and
  `MSFT_ARC_TEST=true`. It is a demo, not a hardened production architecture or
  blanket feature validation. Say so once, early, in your own words.
- **Read numbers off the tiles.** This page carries no counts, because they move as
  the lab runs. A parked or thin-evidence lab says so on the page: read the message
  aloud and do not explain it away.
- **Name the gaps.** "No data", "insufficient evidence" and "not assessed" are the
  point of these views. Say them out loud; they are why the numbers can be trusted.
- **Stay out of** a machine's **Extensions** page, the experimental governance
  workbook and the nested guest's Monitoring, best practices and Defender panes. They
  show lab artifacts or are not enabled; the reasons are in the operator notes.

Every chapter has the same shape: the customer's question and the thread; what to
show, in order; what to say (written to be spoken, about 40 seconds); one wow
moment; a bridge into the next chapter; and a short watch-outs box for the
guardrails and the questions you may be asked.

## Stage setup (two minutes, before you start)

- **Open every workbook from the gallery, each in its own tab.** In
  [the workspace]({{workspaceUrl}}), **{{workspaceName}}**, open **Workbooks**, then open
  the estate workbook, Machine Intelligence Center, Compliance, SQL Estate, Capacity and
  Optimisation (and Asset Inventory if you will show it), one tab each, and finish on the
  estate tab. A workbook opened from the gallery shows its display name in the title; one
  opened by a direct link shows its ID. The links in this guide are the fallback, not the
  way in: where a chapter says "Open", switch to that tab.
- **Make the grids fit.** Set browser zoom to 100 percent (90 percent on a smaller screen),
  collapse the portal's left menu, press F11 for full screen and hide the favourites bar. A
  narrow window clips table headers and cells.

## Opening: the Monday-morning questions (1 minute, clock 0:00 to 1:00)

Act: open. Pain points: all of them. Have [the estate workbook]({{workbookUrl}}) open
behind you and do not click yet.

**Read aloud:**

> "It's Monday morning and three questions land on your desk. How many servers do we
> really run, and are they healthy and safe? Do we have room for the next project,
> and are we paying for things we don't use? And if something breaks at 2 a.m., who
> finds out first: us, or our users? Today that takes several tools, a few
> spreadsheets and some phone calls. Over the next half hour we'll answer it from one
> place, across Windows, Linux and SQL Server, following one database, the orders
> database, from 'what is it?' to 'what wakes us at night?'. Everything in this first
> half is read-only."

**Ask the room:** "Before I show you ours: how many places would you open today to get
a count of your servers that you trust, and how old is that count?"

**Bridge:** "Let's start with the first question: what do we actually have?"

> **Watch-outs / if asked**
>
> - The thread needs the prepared SQL host. If chapter 4 says no real SQL workload is
>   recorded, tell the story without the thread: every chapter still stands alone.
> - Do not promise numbers. Wait for the first tiles and read them as they are.

## Chapter 1. What do we actually have? (3 minutes, clock 1:00 to 4:00)

Act: understand. Pain point: 1 Resource visibility. Engineer task 1.

> **The customer's question:** "How many servers do we actually run, and which of them
> can I trust the data on?"
>
> **The thread:** point at {{SqlHostPhrase}} in the list. That is where the orders
> database lives.

Open [the estate workbook]({{workbookUrl}}).

**Show, in this order:**

1. The **Estate** tiles. Say the two numbers that matter first, off the tiles:
   **Arc machines** (everything Arc knows about) and **Reporting now** (sending data in
   the last 15 minutes). Then **Windows**, **Linux** and **SQL instances**.
2. **Hosts reporting over time (zero when parked)**: the honest line. A parked period
   reads as zero, not as a gap someone filled in.
3. In **Arc machines (select a row)**, select {{SqlHostPhrase}}, then open the
   **Machine detail** tab: its connection, updates, load and recent errors in one
   place.
4. Optional (adds about a minute): {{AssetInventoryAvailability}} If you opened it,
   show **Estate at a glance**, **Server inventory** and **Tag coverage**, then
   return.

**Say:**

> "These are the servers we've connected to Azure Arc: Windows, Linux and SQL, in one
> list. In this lab they're Azure VMs standing in for on-premises machines, which is a
> documented way to evaluate Arc, so what you see is representative. Two numbers
> matter first: how many machines Arc knows about, and how many are sending data right
> now. When they differ, the page tells you why instead of rounding it away. Now I
> pick one server and the page follows it: connection, updates, load, recent errors.
> That's the Monday answer: not a spreadsheet from last quarter, but a list that knows
> what is reporting and what isn't."

**Wow:** select the SQL host's row and open **Machine detail**: two clicks from the
whole fleet to one server's evidence.

**Bridge:** "That's the fleet. Now pick one server and see whether an engineer can
understand it without logging in to it."

> **Watch-outs / if asked**
>
> - This lab simulates on-premises servers using Azure VMs and `MSFT_ARC_TEST=true`.
>   It is a demo, not a hardened production architecture or blanket feature validation.
> - A machine with no monitoring agent (the nested SQL guest is one) is in the Arc
>   count but not in the reporting count, and the grid says so in its note. If the two
>   numbers differ, read that note. A parked period reads as zero hosts reporting,
>   which is expected and is not continuous uptime.
> - **Updates pending** and the **Posture** tab read the latest Update Manager
>   assessments: a failed or never-run assessment is shown as such and is never counted
>   as patched. If **Tagged** is below 100, say why a machine is untagged; the
>   **Posture** tab lists it.
> - If a tile is empty, read its message aloud, say so and use the
>   [fallback queries](#fallback-queries). **Events and logs** and **Changes and
>   software** answer "what is logging errors" and "what changed" if someone asks.
> - If the workbook is slow, the same list is in the portal:
>   [the Arc resource group]({{ResourceGroupUrl}}) (narrow it with the **Type**
>   filter).

## Chapter 2. Show me one server (4 minutes, clock 4:00 to 8:00)

Act: understand. Pain points: 2 Infrastructure complexity, 5 Training and skills.
Engineer task 1.

> **The customer's question:** "Can one of my engineers understand a Windows server and
> a Linux server the same way, without logging in to either?"
>
> **The thread:** the orders database's pulse, from the server it runs on.

{{MachineIntelligenceAvailability}}

**Show, in this order:**

1. In **Machine**, pick {{SqlHostPhrase}}. Under **Machine at a glance**, **Arc
   identity** is its Azure resource identity and **Newest telemetry** is how fresh its
   data is, without logging in.
2. The **Performance** tab for CPU, memory and free disk, then the **SQL Server** tab:
   **SQL worker events over time** is the orders database's pulse.
3. Switch **Machine** to the Linux host **{{linuxMachineName}}**: the same tabs and the
   same charts.
4. The data collection rule behind all of it, in the last minute of this chapter.

**Say:**

> "Now suppose an engineer is asked about one server. They don't log in. They pick it
> here and see its Azure identity, how fresh its data is and how it's performing. This
> is the SQL host, and this is the orders database's pulse from Azure Monitor. Now I
> switch to a Linux host: same tabs, same charts. Windows or Linux, one way of working.
> That's the skills point: an engineer who already knows Azure already knows how to use
> this. No remote desktop, no SSH, no separate console."

**Wow:** switch **Machine** from the SQL host to a Linux host and the page does not
change shape.

### How the data gets here (the last minute of chapter 2)

{{DataCollectionRuleAvailability}}

Show its **Resources** (the machines it applies to) and **Data sources**.

**Say:**

> "The Azure Monitor Agent collects the telemetry. The data collection rule is the
> control plane: it says what to collect and where to send it. One rule serves many
> machines, and its selectors keep ingestion small; the Windows event selectors are
> split by level, so nothing is collected twice. We extended this rule during the
> build, adding the Linux memory and disk counters and the SQL events, and the data
> followed within a couple of minutes."

**Bridge:** "It's reporting and it's healthy. But healthy isn't the same as safe: is it
up to date, and does it meet our policies?"

> **Watch-outs / if asked**
>
> - Read-only: do not edit the rule, and say nothing about cost savings.
> - Arc gives each server an Azure resource identity without making it an Azure VM.
>   Tags describe intent; they do not prove compliance, active antivirus or a purchased
>   licence.
> - Do not open a machine's **Extensions** page. In this lab the Windows hosts get the
>   Azure Monitor Agent as an Arc extension, but the Linux hosts get it, and Change
>   Tracking, as Azure VM extensions: an artifact of simulating on-premises servers
>   with Azure VMs. A real on-premises server gets the agent as an Arc extension and
>   authenticates with the Arc machine's managed identity.
> - The SQL host has no Arc SQL instance, so the instance and database tables on the
>   **SQL Server** tab say so: that is a different system, met in chapter 4. A host with
>   no Azure Monitor Agent (the nested SQL guest) shows no load and says so: missing is
>   not zero. Stay off its **Security** tab.
> - If someone asks to see the Arc side in the portal:
>   [the Linux Arc machine]({{linuxMachineUrl}}), **{{linuxMachineName}}**, on
>   **Overview** and tags.

## Chapter 3. Are we safe and up to date? (3 minutes, clock 8:00 to 11:00)

Act: understand. Pain points: 1 Resource visibility, 7 Operational efficiency.

> **The customer's question:** "If an auditor asked how compliant and how patched we
> are, could we answer today, and prove it?"
>
> **The thread:** the SQL host is in the same table as everything else: same rules,
> same evidence.

{{ComplianceWorkbookAvailability}}

**Show, in this order:**

1. **Posture at a glance**: read **Policy compliance**, under **Policy and secure
   score**, off the tile. This lab is intentionally un-hardened, so a low score is the
   honest baseline, not a failure of the demo.
2. **Patching and Defender agent**: **Fully patched**. Then, under **Patch posture**, the
   **Patch status** tiles: **Security pending** and **Assessment gaps**.
3. The table **Arc servers with pending critical or security updates**: one row per
   server, with its real state.
4. Open [the Windows Arc machine]({{windowsMachineUrl}}), **{{windowsMachineName}}**, then
   **Updates**: point to **Last assessed** and the missing-update rows.

**Say:**

> "Healthy isn't the same as safe. Two honest numbers. Policy compliance is low, because
> this lab is deliberately un-hardened: that's the baseline I'd stand behind, and
> visibility comes before an agreed change. Then patching. Fully patched can read zero,
> and that's the truthful answer: the table shows which servers have updates pending,
> whose assessment didn't complete, and which have never been assessed. This view never
> counts 'don't know' as 'fine'. Open a server and you see the actual updates. We assess
> here; changing anything is a planned decision."

**Wow:** the number that looks worst, **Fully patched**, is the most honest one, and the
table says why, server by server.

**Ask the room:** "If an auditor asked 'how patched are you?' today, who would answer, and
how long would it take?"

**Bridge:** "That's the fleet's posture. Now the system you'd actually lose sleep over:
the database."

> **Watch-outs / if asked**
>
> - Stand behind the **Policy compliance** figure for governance: it is the honest
>   un-hardened baseline, a governance story and not a demo failure.
> - **Fully patched**, **Patch status** and the table read the latest Update Manager
>   assessments, so they agree with the **Updates** view above. A machine whose
>   assessment failed or has not run says **Assessment failed** or **Not assessed**, is
>   counted under **Assessment gaps** and is never counted as **Fully patched**; in this
>   lab that has been the case for the Linux hosts (their patch extension was not ready,
>   an artifact of simulating on-premises with Azure VMs, and an assessment can read in
>   progress while it runs) and is the case for the experimental nested guest. The
>   counts reflect the last assessment time, not live state, and the **Updates** view
>   above is the per-machine drill-down.
> - Update Manager is free for Azure VMs but billed for Arc-enabled servers, so do not
>   describe it as free (exceptions are in the
>   [pricing FAQ](https://learn.microsoft.com/azure/update-manager/update-manager-faq#pricing)).
> - Policy assignment is not evaluated compliance. Monitor readiness is not active AV,
>   full EDR, patch completion or application proof.
> - If there is no assessment data, say so and move on; do not select **Check for
>   updates**, install updates or alter schedules.
> - Keep the experimental governance workbook off this path. It returns data, but it is
>   labelled experimental, repeats the policy story told here, and its **Vulnerability
>   findings** section is marked not applicable in this lab.

## Chapter 4. What about the database? (3 minutes, clock 11:00 to 14:00)

Act: understand. Pain points: 2 Infrastructure complexity, 6 Migration and
modernisation.

> **The customer's question:** "My databases matter more than my web servers. What do we
> actually know about them?"
>
> **The thread:** the orders database in focus, and the rule that watches it.

{{SqlEstateAvailability}}

**Show, in this order:**

1. **SQL at a glance**: two kinds of evidence. **Arc inventory** is what Azure Arc
   registered; **Monitored SQL workload** is what a real SQL workload reports through
   the Azure Monitor Agent, with no Arc SQL involved. Then **Alert rule** and
   **Alerts**: the rule that watches the workload.
2. **What Azure Arc inventories**: **SQL Server instances registered with Arc** and
   **Databases discovered by Arc**, with the **Edition mix**, **Version mix** and
   **Licence mix** tiles. Say the boundary first (see Say).
3. **What Azure Monitor observes**: **Healthy commits per minute**, then **Lock
   timeouts and recoveries** and **Lock-timeout incidents (SQL error 1222)**:
   earlier incidents, dated.
4. **Alerts raised by the lock-timeout rule**: the same rule that starts the night
   shift in chapter 7.

**Say:**

> "Two kinds of evidence about SQL, in one place. On this side, what Azure Arc knows: an
> instance on the nested guest, its version, edition, licence and databases. That one is
> experimental: SQL Server on an Azure VM isn't a supported Arc SQL configuration, so it
> shows how the experience works, not production support. On this side, what Azure
> Monitor observes: a real workload committing orders every minute. When it hits a lock
> timeout, it leaves a mark, here, with a recovery after it. And a rule is watching for
> exactly that mark. Hold on to it."

**Wow:** **Lock timeouts and recoveries** draws a past incident as a spike and a
recovery, next to the rule that watches for it.

**Bridge:** "So we know what we have and what it is doing. Now the planning question: is
there room for what comes next?"

> **Watch-outs / if asked**
>
> - Say the boundary before you are asked: the nested guest runs in license-only mode,
>   so what you see is connection and inventory, not monitoring or assessment. SQL
>   Server on Azure virtual machines is not a supported Arc SQL configuration and this
>   guest runs nested on an Azure VM, so it shows how the experience works, not
>   production or support validation.
> - Do not claim Monitoring, best practices assessment or Defender for SQL on this
>   instance, and do not open those panes. Best practices assessment, Monitoring and
>   Defender for SQL are not demonstrated on any host. The last section, **Best
>   practices assessment: not enabled in this lab**, says why it is empty; leave it
>   closed.
> - Subscription-level Defender settings can add the Defender extensions, and a
>   Protected status, to a host independently of this lab. If asked, say: "that is
>   present through subscription-level Defender settings; we make no Defender claim for
>   an experimental nested guest."
> - Engine proof, dated: {{SqlAvailability}} Fresh Information rows (about one a minute)
>   corroborate it; old evidence or SQL-shaped simulator events do not prove a running
>   engine today. No rows means a gap: say so. Do not install, restart or change
>   collection.
> - {{NestedSqlAvailability}} Inventory can lag; database changes appear
>   in the portal within about an hour, so judge freshness by **Last collected time**,
>   not by the guest being up. If the guest or instance shows **Disconnected** or
>   **Expired**, or has no databases, say it is not available in this run and stay on
>   the Azure Monitor half. The presenter never starts or repairs it.
> - The guest runs on a Hyper-V parent host that is itself an Azure VM, a disclosed lab
>   detail. In the capacity workbook (chapter 5) the parent and the guest are separate
>   rows and are never added together.

## Chapter 5. Do we have room for what is next? (3 minutes, clock 14:00 to 17:00)

Act: plan. Pain point: 3 Capacity planning. Engineer task 2.

> **The customer's question:** "A new project wants capacity. Do we have it, and how sure
> are we?"
>
> **The thread:** find the SQL host's row. Does the orders database's server have room?

{{CapacityWorkbookAvailability}}

**Show, in this order:**

1. **Scope and evidence quality** (the first row of tiles): **Machines in scope**,
   **Reporting now**, **Latest sample** and **Adequate evidence**. Can this view be relied
   on at all? A parked or thin-history estate reads as a plain message, not an error.
2. **Where should engineers look first?**: the **Estate capacity summary** tiles
   (**Pressure observed**, **Apparent headroom** and **Within thresholds**, then **Insufficient
   evidence** and **No telemetry** on the second row) and the table **Status and evidence
   quality by machine (select a row)**. Find the SQL host's row.
3. The **CPU** tab: **CPU 95th percentile by machine** beside **CPU peak by machine**, then
   **Sustained versus brief: what the numbers say**.
4. If the nested guest is part of this run, **Declared parent and guest (side by side,
   never summed)**: the parent host reads **Insufficient evidence**, never headroom, and
   the guest says it has no telemetry.

**Say:**

> "Before anyone's told to resize anything, ask how much evidence we have. This first row
> says whether the view can be relied on: how many machines, how fresh, how much history.
> Then the status of each machine: pressure, headroom, or 'we don't know yet'. And here's
> what engineers often get wrong: a brief spike isn't pressure, a sustained run is. Left
> chart, what a server does most of the time. Right chart, its peaks. This view says
> 'insufficient evidence' when that's the truth, and it never adds a Hyper-V host and its
> guest together."

**Wow:** the two charts side by side: what a server does most of the time, against its
peaks.

**Ask the room:** "When someone asks you for capacity, how much history do you have in
front of you before you say yes?"

**Bridge:** "There is room on paper. The next question is whether any of what we are
running is paid for and not used."

> **Watch-outs / if asked**
>
> - The thresholds on the page, including **Evidence needs**, are illustrative and
>   editable, and the evidence rule is modest for a lab that runs on demand. Leave them
>   at their defaults; the page says so.
> - Missing data is not zero and parked gaps are not idle headroom; low CPU alone is not
>   a sizing instruction. Parent and guest rows are separate observations, never additive
>   hardware capacity.
> - Linux memory and disk report alongside Windows (the counters were added to the data
>   collection rule), so Linux history starts when they were added. A counter with too
>   little history is labelled thin, never guessed.
> - Do not induce load, activate hosts or change collection to populate a tile.

## Chapter 6. Where is the money going? (3 minutes, clock 17:00 to 20:00)

Act: prioritise. Pain points: 8 Cost optimisation, 6 Migration and modernisation.
Engineer task 2, continued.

> **The customer's question:** "What are we paying for and not using, and how do I know
> that before I switch anything off?"
>
> **The thread:** is the SQL host a candidate? If it is not flagged, that is an answer
> too: not flagged on this evidence.

{{OptimisationWorkbookAvailability}}

**Show, in this order:**

1. **Opportunity summary**: the **Review reasons** tiles (**Machines reviewed**, **Low
   utilisation**, **Scheduling** and **Consolidation**, then **Ownership gaps** and **Not
   reporting** on the second row) and **Review reasons by evidence quality**. A machine can
   carry several reasons; these are conversation starters, not savings.
2. In **Review candidates (select a row for the review detail)**, select one machine, then
   open the **Review detail** tab. The **Review card** explains each reason, the evidence
   window, what is still missing, the published owner tags, the next human decision and
   what the workbook will never do.
3. The **Scheduling and scenario** tab: the heat-map of when the machine is idle. For a
   worked example, enter an illustrative baseline; the labelled scenario shows the effect
   of fewer running hours.
4. The **Consolidation** tab: groups side by side, with peaks never added.

**Say:**

> "Now, where's the money going? This doesn't say 'delete this'. It says: this server
> deserves a conversation. Here's why it was flagged, how sure we are, who owns it, and
> what we still don't know. The scenario is an illustration with your own number in it,
> not a saving we're promising. Observation and approval are separate: there's no delete
> button, and nothing here changes a server. That's what makes the meeting short: you
> start from evidence, not from an argument."

**Wow:** the **Review card**: why, how sure, who owns it, what is missing and who decides,
and no delete button.

**Bridge:** "That's the day shift. Now the night shift: what happens when something breaks
at 2 a.m.?"

> **Watch-outs / if asked**
>
> - A stale or non-reporting machine is not safe to delete or redundant. The scenario
>   inputs are hypothetical: not billing, not realised savings and not on-premises cost.
>   If asked for a number, say it is the audience's own figure, not a finding.
> - Observation here is separate from approval, and there is no remediation or delete
>   button.
> - A blank ownership tag is missing evidence, not proof that nobody owns the machine.
> - The same evidence (what runs where, how hard, who owns it, what is idle) is what a
>   retain, optimise, modernise or migrate decision needs first: see the prepared answer
>   on migration.

## Chapter 7. What happens at 2 a.m.? (3 minutes, clock 20:00 to 23:00)

Act: operate. Pain point: 7 Operational efficiency. Engineer task 3 starts here.

> **The customer's question:** "When something breaks at 2 a.m., how long before someone
> with the right context is looking at it?"
>
> **The thread:** the lock-timeout rule on the orders database. Tonight's alert starts
> here.

Open [the missing-heartbeat alert rule]({{heartbeatAlertUrl}}), **{{heartbeatAlertName}}**.

**Show, in this order:**

1. The rule: its scope, condition, severity and evaluation window.
2. Then open [the action group]({{actionGroupUrl}}), **{{actionGroupName}}**, to show the
   configured notification route without exposing the recipient or selecting **Test**.
3. The SQL and application rules: {{SqlIncidentAvailability}} {{LobIncidentAvailability}}
   Show each rule's scope, condition and severity. The lock-timeout rule is the one you
   saw drawn into the SQL page in chapter 4.
4. Hand over to the SRE half (next section).

**Say:**

> "So far, the day shift. Now the night shift. A signal becomes a routed action: a rule, a
> severity and an action group. These alerts use the same action group. When the SQL
> worker logs a lock timeout, or the application worker reports a degraded state, an
> alert fires and the SRE agent starts an investigation automatically. The incidents we
> walk through next are the SRE agent's own: any we trigger live are current, earlier
> ones are dated."

**Wow:** the lock-timeout rule is the same signal you saw drawn into the SQL page, now
wired to a route and an investigation.

**Ask the room:** "When something breaks at night today, how long is it before someone
with the right context is looking at it?"

> **Watch-outs / if asked**
>
> - Email is configured on the action group; an integration or a delivered notification
>   needs its own evidence. The demo rule evaluates observed Heartbeat rows, not a
>   complete never-seen-host inventory, so do not promise complete outage detection or a
>   fixed notification time.
> - If alert history is populated, show the affected resource and timestamp. A healthy lab
>   may have no fired alerts: show the rule, not a manufactured outage.
> - If the alert history or an investigation is absent, state that gap and do not
>   manufacture evidence. Nothing is triggered from this Arc path: incidents are
>   triggered, approved and read in the SRE half.
> - An engineer who can read the evidence is not necessarily an approver. Reader and
>   approver are separate roles, and nothing on this Arc path approves or changes
>   anything.
> - Show the original rules before the live-fault copies are prepared (the SRE half's
>   own first step): while the copies exist the originals read as disabled. If they
>   already do, say the copies are the same rules, temporary, and leave the originals
>   alone.

## Hand over to the SRE half

{{CompanionSection}}

**Say:**

> "That was the day shift: what we have, how it's doing, whether it's safe, whether
> there's room and where the money goes, all from one place, all read-only. Now the night
> shift. The orders database we started with is about to have a bad night, on purpose, and
> you'll watch what happens between the alert and a person making a decision."

**Next:** the SRE guide's first step picks the story up from this line. Without the SRE
half, go straight to the close.

> **Watch-outs / if asked**
>
> - If the SRE half runs from dated threads and no live fault, say "had a bad night earlier
>   today" instead of "is about to have one".
> - The SRE guide owns the investigation, the human Review approval and any separate
>   approval to send an investigation or trigger an incident. Arc-only activation never
>   prompts for or induces an incident.
> - Do the close after the SRE half. If the SRE half is not run, do it now.

## The close: the Monday answers (2 minutes)

Say it last: after the SRE half, or straight after chapter 7 if the SRE half is not run.
Return to [the estate workbook]({{workbookUrl}}).

**Say:**

> "Back to Monday morning. How many servers, are they safe, do we have room, where is the
> money going, and who is looking when it breaks? You've seen each answered from one view,
> with the gaps showing as gaps. Arc gave every server, Windows, Linux and SQL, an identity
> in Azure. Azure Monitor gave us evidence that says when it doesn't know. The workbooks
> turned that evidence into decisions we can defend. And the SRE agent turned an alert into
> an investigation while a person decided what, if anything, changed."

| Pain point | What you saw | Where |
| --- | --- | --- |
| 1 Resource visibility | Every server, what is reporting and what is not, and its posture | Chapters 1 and 3 |
| 2 Infrastructure complexity | Windows, Linux and SQL in one view, one way of working | Chapters 2 and 4 |
| 3 Capacity planning | Headroom with the evidence behind it: typical against peak | Chapter 5 |
| 4 Disaster recovery | Not part of this demonstration | Prepared answer |
| 5 Training and skills | Engineers answering real questions from prepared views: no terminal, no subscription ID, no hand-written queries | Every chapter |
| 6 Migration and modernisation | The evidence that comes before the decision: what runs where, how hard, who owns it | Chapters 1, 4, 5 and 6; prepared answer |
| 7 Operational efficiency | An alert that becomes an investigation, with a person in charge of any change | Chapter 7 and the SRE half |
| 8 Cost optimisation | Candidates for a conversation, with evidence and a human decision, never a promised saving | Chapter 6 |

**Next step:** choose one group of servers to start with; we suggest the SQL estate.
Connecting a server to Arc installs the Azure agents on it, and everything we do after
that starts read-only. We point these same views at the group and review together, after
two weeks, what they show: what you have, what is safe, where there is room and where the
money goes.

Leave the lab unchanged. Parking is a separate operator action, with the companion
parked first if present; retained services and storage still cost money.

## Prepared answers

### Disaster recovery (pain point 4, not demonstrated)

> "Disaster recovery isn't part of this demonstration, and Arc doesn't provide it. Arc
> gives you identity, monitoring and governance for servers where they are today. Backup,
> replication and failover are a separate conversation with their own Azure services, for
> example Azure Backup and Azure Site Recovery, and what fits depends on how your servers
> run now. It starts from the same list you've just seen, because you can't protect what
> you can't enumerate. And hibernating this lab is a cost action, not disaster recovery."

### Migration and modernisation (pain point 6, evidence only)

> "We haven't run a migration assessment and none of these views is one: no readiness
> score, no target sizing, no migration cost. What Arc gives you is the evidence that
> comes before that decision: what runs where, which operating system and SQL versions,
> how hard each server works, who owns it and what is idle. That tells you where to ask
> the next question. Moving a workload is optional; Arc improves how you manage it where
> it is. When you do ask 'should it move?', a migration assessment such as Azure Migrate
> is the next tool, and this evidence tells you which servers to start with."

### Other questions

- **Why two agents?** Arc is not a telemetry agent. It gives the server an Azure identity
  and the install path; the Azure Monitor Agent uses that identity to authenticate, with
  no workspace keys.
- **Private link?** The agent needs a data collection endpoint added to an Azure Monitor
  Private Link Scope. This lab uses public endpoints through the NAT gateway.
- **Application log files?** The agent can collect them through a data collection rule;
  the line-of-business app here uses the Windows Event Log.
- **Is Update Manager free?** Free for Azure VMs, billed per Arc-enabled server
  (exceptions are in the FAQ). Never call it free.
- **Why does Linux differ?** Windows hosts get the agent as an Arc extension; Linux hosts
  get it, and Change Tracking, as Azure VM extensions. That is an artifact of simulating
  on-premises with Azure VMs.
- **Is nested Arc SQL supported?** No: it is experimental and license-only. SQL Server on
  Azure VMs is not a supported Arc SQL configuration. Nothing is claimed for Monitoring,
  best practices assessment or Defender for SQL.
- **Can an engineer approve fixes from these views?** No. Reading evidence and approving
  a change are separate roles, and these views never trigger an action.

## Fallback queries

Use these only when a workbook tile is empty or someone asks. They read the same
workspace as the workbooks. Open [the workspace]({{workspaceUrl}}), **{{workspaceName}}**,
and select **Logs**. If needed, switch **Simple mode** to **KQL mode**. Paste one at a
time and use the stated time range.

### Last 10 minutes: who is reporting right now?

```kusto
Heartbeat
| where TimeGenerated > ago(10m)
| where tolower(_ResourceId) startswith "{{ArcScope}}/providers/microsoft.hybridcompute/machines/"
| summarize LastHeartbeat=max(TimeGenerated) by Computer, OSType
| order by Computer asc
```

A missing host is missing evidence, not zero-valued success. A parked machine, or one
with no monitoring agent (the nested SQL guest is one), does not appear.

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

### Last 30 minutes: healthy SQL commits

{{SqlAvailability}}

```kusto
Event
| where TimeGenerated > ago(30m)
{{SqlHostFilter}}
| where Source =~ "ArcSqlEngineDemo" and EventID == 6000
| project TimeGenerated, Computer, EventLevelName, RenderedDescription
| order by TimeGenerated desc
```

This worker really commits orders to SQL Server and reads them back. Fresh Information
rows (about one a minute) corroborate the saved query result. No rows means a gap: say
so.

### Last 30 minutes: healthy application signal

{{LobAvailability}}

```kusto
Event
| where TimeGenerated > ago(30m)
| where tolower(_ResourceId) startswith "{{ArcScope}}/providers/microsoft.hybridcompute/machines/"
{{LobHostFilter}}
| where Source =~ "ArcLobBridgeApp" and EventID == 4000
| project TimeGenerated, Computer, EventLevelName, RenderedDescription
| order by TimeGenerated desc
```

Expect a fresh Information event roughly every minute. If there are no rows, state the
gap and skip this. Do not show an earlier incident as today's activity.

### Last 7 days: recorded SQL incident rows

```kusto
Event
| where TimeGenerated > ago(7d)
{{SqlHostFilter}}
| where Source =~ "ArcSqlEngineDemo" and EventID in (6201, 6001)
| project TimeGenerated, Computer, EventID, EventLevelName, RenderedDescription
| order by TimeGenerated desc
```

These rows are dated history. The lock self-recovers in about 12 seconds, so explain
historical SQL wait evidence, not a currently blocked orders worker or an SRE-performed
remediation.

## Operator notes

These notes are for the operator who prepares and hands over this page. They are
not presenter patter, and nothing here is run during the presentation.

- **Before handing over:** verify Active readiness independently
  (`Test-ArcDemoReadiness.ps1 -DesiredState Active`, read-only with a bounded
  timeout) and poll until any telemetry-only lag clears to a pass; lag is not a
  ready handoff. Open every link on this page once, and open each workbook from the
  workspace's Workbooks gallery too: a workbook opened by a direct link shows its ID in
  the blade title, which is why the stage setup tells the presenter to use the gallery
  and keep the links as the fallback. Check the nested guest with
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
- **Alert history:** Monitor alert history lists older instances and the temporary
  copies of the rules used for live runs. The presenter stays on the rules and the
  workbook tiles.
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
  incident. The handover and closing lines in this page are the ones the SRE guide
  echoes, so change them in both places together.
- **Whole-demo page:** generating with `-SreGuidePath` also writes
  `.local/full-demo-runsheet.md`: a whole-demo table, this guide, the SRE guide's own
  text under "The night shift (SRE half)" (steps headed "SRE step N", its close
  replaced by a pointer to the close here) and then the single close. The SRE guide is
  read, never edited, and generation stops if its headings change shape. Regenerate
  after either guide changes.
- **Editing this guide:** keep each spoken block under about 120 words, keep numbers
  out of this file (they live on the stage card, dated), and keep every bold tile,
  section or tab name exactly as the workbook shows it. Tests check all three. The
  stage card is a private one-page companion beside the generated guide that restates
  the chapter order, the bridges and today's numbers; this page is the source and the
  stage card is not a second runsheet.

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
The prepared answers are grounded in
[Azure Arc-enabled servers](https://learn.microsoft.com/azure/azure-arc/servers/overview),
[Azure Monitor Agent](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-overview),
[data collection rules](https://learn.microsoft.com/azure/azure-monitor/essentials/data-collection-rule-overview),
[Azure Monitor private link](https://learn.microsoft.com/azure/azure-monitor/logs/private-link-security),
[Azure Backup](https://learn.microsoft.com/azure/backup/backup-overview),
[Azure Site Recovery](https://learn.microsoft.com/azure/site-recovery/site-recovery-overview)
and [Azure Migrate](https://learn.microsoft.com/azure/migrate/migrate-services-overview).
The support boundaries are grounded in
[SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/overview?view=sql-server-ver17)
(license types and unsupported configurations),
[SQL Server inventory](https://learn.microsoft.com/sql/sql-server/azure-arc/view-inventory?view=sql-server-ver17),
[evaluating Arc-enabled servers on an Azure VM](https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine)
and [Azure Monitor Agent environments](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-supported-operating-systems#on-premises-and-in-other-clouds).
