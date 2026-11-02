# Capacity and optimisation workbooks

Optional, read-only engineer views built only from telemetry the lab already collects
and from Arc inventory. They are chapters 5 and 6 of the 25-28 minute presenter story
and they never act on a machine. The operator procedure (preview, draft, publish,
remove) is in the [runbook](runbook.md#optional-capacity-and-optimisation-workbooks);
this page says what each view shows and the rules behind it. The first-chapter
[Estate Overview](#estate-overview-chapter-1) is a static template, described after the two.

| Workbook | Story |
|---|---|
| **Capacity and headroom** | Where is the estate under pressure, where does it appear to have headroom, and how far can the data be trusted? |
| **Optimisation opportunities** | Which machines deserve a cost or efficiency conversation, why, and what evidence is still missing? |

Both use the same shared KQL (`workbooks/queries/operational-*.kql`), so identical scope
and window give identical metrics. The item queries (`cap-*`, `opt-*`, `detail-*`) are
composed with an exact Arc roster by `scripts/lib/OperationalWorkbooks.psm1`; the workbook
JSON files are templates that the module renders. Open the workbook cold and read the
tiles, then the status or candidate table, then select a row for the per-machine detail.

## Guardrails

- Missing is never zero. No samples is shown as *No telemetry*, not as an idle or healthy machine.
- Parked gaps are unknown time, not idle headroom. Charts are column charts and an interval with no samples is a blank
  column, never a zero or an interpolated line.
- Evidence quality is shown beside every status: observed hours per counter, sampling while
  active, last sample, invalid samples ignored (never clamped or zero-filled).
- Thresholds are illustrative triage values, not an approved service objective or sizing advice.
- Nothing stops, resizes, schedules, tags or deletes a resource. Reasons are conversation starters
  for a human decision, not savings.
- A declared parent and its nested guest are separate observations. They are never added,
  never counted as extra hardware capacity, and a guest is never a consolidation candidate.
- No fake data is ingested. The opt-in tests use literal tables inside the query text.
- Disaster-recovery and Azure Migrate assessment are out of scope.

## Data sources

One canonical source is chosen per machine and metric across the window, never mixed to hide a
gap. CPU is total CPU, not per-core rows or duplicate `Processor`/`Processor Information` streams.

| Measure | Windows | Linux |
|---|---|---|
| CPU | Perf `Processor Information(_Total)` or `Processor(_Total)` `% Processor Time`; VM insights as fallback | Perf `Processor(*)` `% Processor Time`, instance `total` |
| Memory in use | Perf `Memory` `% Committed Bytes In Use` | Perf `Memory(*)` `% Used Memory` |
| Available memory | Perf `Memory` `Available MBytes` | Perf `Memory(*)` `Available MBytes Memory` |
| Disk free space | VM insights per volume (`FreeSpacePercentage`, `FreeSpaceMB`, size from `vm.azm.ms/diskSizeMB`); `LogicalDisk(_Total)` only as an aggregate fallback | Perf `Logical Disk(*)` `% Free Space` and `Free Megabytes` per mount |

Windows committed bytes and Linux used memory are different counters on one percent scale.
Each machine keeps its own basis; they are compared within a machine, not blended.
Linux pseudo mounts (`/snap`, `/run`, `/dev`, `/sys`, `/proc`, snapd) report 0% free and are
excluded. A Linux volume size is derived from free MB and free percent and labelled *derived*.

### Linux memory and disk counters

The Linux counters are collected through the core data collection rule
(`New-CoreDcrBody` in `scripts/Deploy-ArcDemo.ps1`, table `Perf`, 60-second sampling):
`Memory(*)\Available MBytes Memory`, `Memory(*)\% Used Memory`, `Logical Disk(*)\% Free Space`
and `Logical Disk(*)\Free Megabytes`, named per the
[guest OS metrics reference](https://learn.microsoft.com/azure/azure-monitor/vm/metrics-guest-reference#performance-counters).
Windows hosts are unaffected. The earlier placeholder names (`\Memory(*)\AvailableMemory`,
`\Memory(*)\PercentUsedMemory`, `\Logical Disk(*)\FreeSpacePercentage`) are not valid Linux AMA names and
never produced samples. Ingestion cost is small (four counters from a few hosts). Linux history
starts when the rule is applied, so Linux memory and disk read as thin until enough hours exist.

## Evidence and status model

**Evidence** (per machine): *Adequate* needs the selected observed hours (default 3, an illustrative
setting that lets an on-demand lab be classified within hours of waking; a production review would
ask for far more) for CPU, memory and disk, with sampling while active of at least 80%. Otherwise the table says *Thin history*,
*Sparse sampling while active*, *Memory or disk history thin*, *Memory or disk evidence missing*,
*CPU telemetry missing*, *Invalid samples - investigate*, *Parent counters exclude guest load* or
*No telemetry in window*. **Reporting** means a sample within 15 minutes of the window end.

**Assessment** (mutually exclusive, so the tiles add up to the machines in scope):
*Pressure observed*, *Insufficient evidence*, *No telemetry*, *Within thresholds*, *Apparent headroom*.
Pressure is sustained CPU or memory (continuous five-minute intervals at or above the threshold for
the sustained limit), a volume below the low-free threshold, or available memory under 512 MB.
Apparent headroom needs adequate evidence and CPU P95 below the low-CPU threshold; it is not a sizing recommendation.

**Pattern** (CPU, separate from the assessment because every machine has boot and patch peaks):
*Sustained pressure*, *Brief spike(s)* (peak at or above the threshold that never lasted the sustained limit),
*Steady, low*, *Steady*.

| Threshold (editable, illustrative) | Default |
|---|---|
| CPU high | 80% |
| Sustained for | 30 minutes |
| Memory high | 85% |
| Disk low free | 15% |
| Low CPU P95 | 20% |
| Evidence needs (observed hours) | 3 (illustrative) |

Fixed constants (listed on each workbook's *Evidence and method* tab): available memory under
512 MB is pressure; a five-minute interval needs at least three samples; percent counters outside
0-100 are invalid; low utilisation also needs memory in use P95 below 50%; an idle hour is a full hour
(at least 30 samples) averaging below 5% CPU and scheduling needs at least half of the observed full
hours idle; not reporting means no telemetry or more than 24 hours of silence.

### Parent and guest

The nested guest is declared once in the private skin (`nestedSqlGuest`: parent VM name and Arc machine
name). `Set-OperationalWorkbook.ps1` reads it and declares the pair in the roster; an optional
`-TopologyPath` file may declare more (`schemaVersion` 1, `machines` with `resourceId`, `layer`
of `parent`, `guest` or `standalone`, and `parentResourceId` for guests). A guest that is not yet an Arc
machine in the group is skipped with a warning and appears after Arc onboarding and a republish; a disconnected
guest is still listed, with *No telemetry* until it reports.

A Hyper-V parent's own OS counters do not reflect its guests' load or physical CPU use (see
[Hyper-V CPU statistics](https://learn.microsoft.com/windows-server/administration/performance-tuning/role/hyper-v-server/configuration#cpu-statistics)).
A quiet parent is therefore *Insufficient evidence* (*Parent counters exclude guest load*), never headroom and never a
low-utilisation or scheduling candidate on its own counters; pressure on a parent still counts. The tiles count each
machine once and name the declared guest.

## Capacity and headroom

Filters: time range (default 14 days, because this lab runs sporadically), operating system,
environment and application/role, plus the threshold selectors.

| Section | Shows |
|---|---|
| Scope and evidence quality tiles | Can this view be relied on? Four tiles: **Machines in scope** (with the guest caption), **Reporting now**, **Latest sample** (minutes, hours or days since the newest sample) and **Adequate evidence** (with the median window coverage, which counts only machines with CPU samples and is parked time, not idle time) |
| Estate capacity summary tiles | The five assessments on two rows (**Pressure observed**, **Apparent headroom**, **Within thresholds**; then **Insufficient evidence**, **No telemetry**), which add up to the machines in scope. Count tiles carry no colour; each names up to two machines |
| Status and evidence table | One row per machine, worst first: assessment, evidence, CPU P95 and peak, memory P95 and lowest free space. Selecting a row drives *Resource detail* |
| Declared parent and guest | The pair side by side, never summed |
| CPU tab | P95 and peak column charts by machine with the threshold line; sustained-versus-brief table (mean, P95, peak, share of time over the threshold, longest run, trends) |
| Memory tab | Memory in use P95 and lowest available MB by machine, per-machine evidence with the basis |
| Disk tab | Lowest free space over time; per-volume table (lowest free space first) with size, change and state |
| Resource detail tab | Seven tiles (assessment, reporting, evidence, CPU, memory, tightest volume and the application context), a *Why this assessment* table that wraps the explanation into readable lines, paired P95 and peak CPU columns, memory in use and lowest available memory for the one machine, per-volume disk, parent/guest context and every counter's evidence |
| Evidence and method tab | How figures are built, rules and constants, coverage matrix, counters by OS, live Arc inventory |

*Reporting now* means a sample within 15 minutes of the window end; for a custom past range the tile reads
*Reporting at end*. With every machine parked it reads 0 with the caption *parked or silent*, and *Latest sample* gives the
age of the newest sample, which is the data the figures below describe. When no machine in scope has sent any telemetry the
caption reads *no telemetry in window*, *Latest sample* reads *none* and there is no coverage figure: unknown, not zero.
A mix of reporting and silent machines reads *N not reporting*; the table below names each one.

## Optimisation opportunities

Same filters and thresholds. Each reason is *Flagged*, *Needs evidence* or *Not flagged*; a missing
measurement is never read as a clean result.

| Reason | Flagged when |
|---|---|
| Low utilisation | Adequate CPU and memory evidence, CPU P95 below the low-CPU threshold, memory in use P95 below 50%, no pressure signal; never for a parent on its own counters |
| Scheduling | The owner-maintained environment tag is non-production (dev, test, uat, qa, stage, sandbox, demo, lab, poc, nonprod, preprod) and at least half of observed full hours are idle; a blank tag is *unclassified*, never assumed |
| Consolidation | Two or more low-utilisation non-guest machines share an application or role and operating system; peaks are not additive and no placement is implied |
| Ownership gap | The published tags lack an owner, cost centre, environment or application/role; evidence gap, not proof that nobody owns it |
| Not reporting | No telemetry, or silent for more than 24 hours; stale does not mean redundant or safe to delete |

Sections: opportunity tiles (**Machines reviewed**, **Low utilisation**, **Scheduling**, **Consolidation**; then
**Ownership gaps** and **Not reporting**), reasons by evidence quality, candidate matrix (select a row), *Underutilisation*,
*Scheduling and scenario*, *Ownership and hygiene* (live Resource Graph tags and the not-reporting list),
*Consolidation*, *Review detail* (every flagged reason, evidence window, what is still needed, published owner tags,
size context, the next human decision and what the workbook never does, as a Full-size card that wraps long sentences
into lines) and *Evidence and method*. The review detail charts the selected machine's CPU 95th percentile and peak, memory
in use and free space as column charts.

The **optional cost scenario** is arithmetic on figures typed into the workbook for one selected workload:
`baseline x eligible share x hours off / 168`. It is not billing, a price, realised or guaranteed savings, a safe
shutdown schedule or an all-in cost; fixed, licensed, retained-storage, monitoring and security costs stay outside
the reduction. No guest scenario is offered. `Get-DemoOperationalScenario` is the reference implementation the tests compare against.

The live Arc inventory and ownership tables read Resource Graph for the exact roster IDs and follow the same
operating-system, environment and application selectors using each machine's **current** tags.

Each workbook links to the other: *Capacity and headroom* from the header and the consolidation and review-detail
tabs of *Optimisation opportunities* (the plan's links to capacity and dependency evidence), and *Optimisation
opportunities* from the header and the resource-detail tab of *Capacity and headroom*. They are plain portal
hyperlinks that open the sibling with its own default scope, and a draft links to the draft while a published
workbook links to the published one, so publish both for the links to resolve.

## Estate Overview (chapter 1)

The first impression: which Arc machines exist, whether they are connected and sending telemetry, how busy they are,
what changed and what needs attention. Unlike the two workbooks above it is a **static, self-contained template**
(`workbooks/arc-demo-overview.workbook.json`, no deploy-time tokens), so `Deploy-ArcDemo.ps1` Phase 11 publishes it as
is, apart from pinning its Log Analytics items to the deployment workspace, and no roster or rendering step is involved.

- **Story, top to bottom.** Eight *Estate* tiles (Arc machines, Reporting now, Windows, Linux, SQL instances, Tagged,
  Updates pending, Alerts fired); *Hosts reporting over time*, which reads zero when parked and draws the Arc inventory as
  a baseline; *CPU average by machine*; the *Arc machines* grid (select a row); then tabs for memory, disk and CPU peaks,
  events and logs, changes and software, posture, and the selected machine's detail.
- **Reading aids.** Chart legends list series names and colours only, never summed totals. The *Arc machines* grid prints
  CPU, memory and disk as percentages with one decimal, and the alert time is shown in the viewer's local time. Every table
  uses the Full size, because a Small or Medium table reserves a fixed height and leaves a blank band under a short table.
  Only charts of the same height share a row, because a row takes the height of its taller item and leaves a blank band
  under the other; tables are stacked. Column widths follow the Learn grid guidance: short columns are fixed in characters
  (header length plus six, so a header is never cut), the one long text column (rule, source, software, note) takes the
  remaining width (`fr`), and timestamps get 28 characters in the viewer's local time.
  Selecting a machine with no Azure Monitor Agent (the nested guest) shows one warning in *Machine detail* instead of five
  empty charts and tables; the grid passes that state on through a second exported parameter, `DetailMode`.
- **Filters.** Time range (default 24 hours), operating system, environment and role. Environment and role options are read
  live from the Arc machines' tags (an empty tag reads *(untagged)*). Every filter defaults to *All*, which means no
  filtering, and the queries also accept an empty value, `value::all` and `*`.
- **Data.** The Arc inventory, Update Manager assessments (`patchassessmentresources`), Arc SQL instances and alerts come
  from Azure Resource Graph and are read inside the Log Analytics queries with `arg("")`, so one query can combine them
  with Heartbeat, Perf, InsightsMetrics, Event, Syslog and Change Tracking.
- **Honest numbers.** *Arc machines* counts the inventory once. *Reporting now* needs a heartbeat in the last 15 minutes,
  so a machine with no Azure Monitor Agent (the nested SQL guest) is present but not reporting, and the grid says so; last
  heartbeat looks back 14 days. Load uses the same canonical CPU, memory and disk counters as *Capacity and headroom*, and
  a blank is missing data, never zero. *Updates pending* is the latest Update Manager assessment: a failed or never-run
  assessment is shown as such and is never counted as patched. *Alerts fired* counts every alert rule in the subscription
  for the time range. There are no thresholds here; classification lives in *Capacity and headroom*.
- **Empty states.** Every query item has a specific no-data message. No Log Analytics item sets a time context, because
  that would cut the 14-day heartbeat look-back to the time range.

## Look and feel

Both operational workbooks follow the Estate Overview header convention (title, then an italic story line). Expected empty states, such as
a filter with no match, a missing selection or a parked gap, are calm informational bars; amber appears only where an
absent result is itself a finding (no CPU samples, no Arc machines for the roster), and green where emptiness is good
news. Status icons and colours use only the documented grid icon names and the colour and palette names of the
official sample workbooks; an offline test enforces that, because an unknown name renders as nothing.

### Portal layout

The layout of every query item lives in one place, `workbooks/operational-layout.json`, and
`Set-DemoOperationalLayout` in the module applies it after the query tokens are resolved. Every query item needs an entry and
every entry must name an item, so a new tile cannot ship without a layout. In the two template files a grid's own settings
matter only for its status colour rules; the layout replaces every other grid, chart and tile setting when the workbook is
rendered. The rules, each enforced by `tests/OperationalWorkbooksLayout.Tests.ps1`:

- **Tables** use the Full size so a short table leaves no blank band (a Small or Medium grid reserves a fixed height), and
  are bounded: one row per machine of the 50-machine roster, or an explicit `take`. Every column is a proportional `fr`
  width, so a grid fits any container instead of pushing columns off screen; the widths add up to at most 115, each header
  fits its column, and one long column takes the room. Status columns keep the colour rules written in the template.
- **Numbers** are one format per column: percentages are bars on a fixed 0 to 100 scale that print one decimal. In
  *Capacity and headroom* load runs green to red and free space red to green; in *Optimisation opportunities* the bars are a
  neutral blue, because low utilisation is the flag there and not a health signal. Plain numbers pad to one decimal or none.
- **Times** are the viewer's local time in a date renderer wide enough for the clock; text that must name a time states the
  display offset (for example *UTC+10:30*), never a bare UTC clock.
- **Charts** are column charts. A missing interval is a null, so parked time is blank rather than zero or a line across the
  gap. Charts by machine are clustered, not stacked, so percentages are never added; a single-machine chart has one series.
  Legends carry no summed totals.
- **Tiles** carry no palette colour (a left-bar colour must mean something, and the status dot already does), show at most
  four per row, and keep a short label and a short caption: a fixed tile is about 160 px wide, so a caption names one machine
  and a count (*lnx-app-01 +2*), never a list. The five assessments and the six review reasons are split over two rows.
  Detail and scenario tiles size to their content.
- **Explanations** that are longer than a cell are wrapped into lines by the query (the *Why this assessment* table and the
  *Review card*), because a grid cell cuts a long sentence off.

## Publish, review and promote

Preview is the default and writes nothing. Publication is a separate approved operation with the same explicit
subscription, tenant, prefix and skin. The deterministic ID derives from the workspace and purpose; a foreign
workbook is never adopted, and exact serialized content is read back after deployment.

A review copy is a separate resource named *... (draft)* with its own ID, a `lifecycle: draft` tag and a banner;
the published workbook stays intact. Promotion is the same command without `-Draft` and replaces the published
workbook in place. `-Action Remove -Draft` deletes only an owned draft and needs no Arc roster.

The roster is bounded (1-50 exact Arc IDs) because every item query embeds it. Republish to pick up new hosts,
tag changes or a newly onboarded nested guest.

## Validation boundaries

- Offline Pester (`tests/OperationalWorkbooks.Tests.ps1`) covers rendering, scoping, roster and topology rules, size bounds,
  draft handling, sibling links, the documented icon, colour and palette names, empty-state styles and scenario arithmetic.
- `tests/OperationalWorkbooksLayout.Tests.ps1` guards the portal layout offline: fr widths and headers that fit, Full-size
  bounded tables, percentage and number formats with the right colour direction, local times, column charts with null gaps and
  no legend totals, colourless tiles with at most four per row, the layout pass's refusals and the display-offset label.
- `tests/OperationalWorkbookQueries.Tests.ps1` is explicit opt-in and read-only. It runs the production item queries against
  deterministic literal tables (spike versus sustained, missing counters, thin history, parked gaps, invalid samples, Linux
  names and pseudo mounts, parent/guest, tags, scenario arithmetic) with the telemetry sources swapped inside the query text.
  Pass the workspace, subscription and tenant through `New-PesterContainer -Data`. It ingests nothing.
- `tests/EstateOverviewWorkbook.Tests.ps1` covers the static Estate Overview offline: no tokens or identifiers, defaults and
  All handling, a flat option list, no-data messages, the honest tile logic, colour meaning, chart legends, grid headers and
  number formats, the local alert time, the no-agent detail state and the names chapter 1 of the presenter template uses. It is
  explicit opt-in for the live part: pass the workspace, subscription and tenant through
  `New-PesterContainer -Data` to run its Log Analytics items read-only under every form of All.
- `tests/RunsheetWorkbookNames.Tests.ps1` is the presenter name guard: every bold tile, section or tab name in a chapter of
  `docs/runsheet.md` must exist in the workbook that chapter opens (the Capacity and Optimisation tile labels live in
  `workbooks/queries`), so a workbook rename fails a test instead of surprising the presenter.
- Query execution against the real workspace and portal rendering are separate evidence. A passing mock or query run does
  not prove the portal draws a tile or chart the way it should; review the draft in the portal first.
- `arg()` inside a Log Analytics item works in the portal and through `api.loganalytics.io`, but the ARM
  `workspaces/query` endpoint rejects it with a CLI token (`QueryValidationError`: "The 'adx' pattern cannot be used with
  the current authentication scheme"). Validate such items through `api.loganalytics.io`; that ARM error is a limit of the
  check, not of the workbook.
