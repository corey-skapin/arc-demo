# Capacity and optimisation workbooks

Optional, read-only engineer views built only from telemetry the lab already collects
and from Arc inventory. They are scenes 4 and 5 of the 25-30 minute presenter path
and they never act on a machine. The operator procedure (preview, draft, publish,
remove) is in the [runbook](runbook.md#optional-capacity-and-optimisation-workbooks);
this page says what each view shows and the rules behind it.

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
- Parked gaps are unknown time, not idle headroom. Charts omit absent intervals instead of drawing zero.
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
| Scope and evidence quality tiles | Can this view be relied on? Machines in scope (with the guest caption), reporting now, minutes or hours since the latest sample, adequate evidence, limited evidence (named) and median window coverage. Coverage counts only machines with CPU samples and is parked time, not idle time |
| Estate capacity summary tiles | The five assessments, which add up to the machines in scope |
| Status and evidence table | One row per machine, worst first: state, assessment, evidence, CPU P95 and peak, pattern, observed trend, memory, free space, history hours, reason. Selecting a row drives *Resource detail* |
| Declared parent and guest | The pair side by side, never summed |
| CPU tab | P95 and peak charts with the threshold line; sustained-versus-brief table |
| Memory tab | Memory in use P95, lowest available MB, per-machine evidence with the basis |
| Disk tab | Lowest free space over time; per-volume table with size, change and state |
| Resource detail tab | Seven tiles (assessment, reporting, evidence, CPU, memory, tightest volume and the application context: application, environment, owner, cost centre, size), CPU, memory, available memory, per-volume disk, parent/guest context, every counter's evidence |
| Evidence and method tab | How figures are built, rules and constants, coverage matrix, counters by OS, live Arc inventory |

*Reporting now* means a sample within 15 minutes of the window end; for a custom past range the tile says
*at the window end*. With every machine parked it reads 0 and says the figures below describe the last observed data.
When no machine in scope has sent any telemetry it says so instead and treats the result as unknown, not zero, with no
latest sample and no coverage figure; with a mix it says that only the silent machines have observed data.

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

Sections: opportunity tiles, reasons by evidence quality, candidate matrix (select a row), *Underutilisation*,
*Scheduling and scenario*, *Ownership and hygiene* (live Resource Graph tags and the not-reporting list),
*Consolidation*, *Review detail* (every flagged reason, evidence window, what is still needed, published owner tags,
size context, the next human decision and what the workbook never does) and *Evidence and method*.

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

## Look and feel

Both follow the Estate Overview header convention (title, then an italic story line). Expected empty states, such as
a filter with no match, a missing selection or a parked gap, are calm informational bars; amber appears only where an
absent result is itself a finding (no CPU samples, no Arc machines for the roster), and green where emptiness is good
news. Status icons and colours use only the documented grid icon names and the colour and palette names of the
official sample workbooks; an offline test enforces that, because an unknown name renders as nothing.

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
- `tests/OperationalWorkbookQueries.Tests.ps1` is explicit opt-in and read-only. It runs the production item queries against
  deterministic literal tables (spike versus sustained, missing counters, thin history, parked gaps, invalid samples, Linux
  names and pseudo mounts, parent/guest, tags, scenario arithmetic) with the telemetry sources swapped inside the query text.
  Pass the workspace, subscription and tenant through `New-PesterContainer -Data`. It ingests nothing.
- Query execution against the real workspace and portal rendering are separate evidence. A passing mock or query run does
  not prove the portal draws a tile or chart the way it should; review the draft in the portal first.
