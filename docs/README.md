# Arc documentation

## Present the demo

Open **`.local/presenter-runsheet.md`** from the repo root and follow it top to
bottom. To see what the finished lab looks like first, the README's
[What you get](../README.md#what-you-get) shows the six published workbooks from a
rebuilt lab estate (the images are in [images/](images/)).
[runsheet.md](runsheet.md) is the single source template; you
[generate the guide](runbook.md#prepare-the-local-presenter-guide) from saved
local context. Generation is offline, not a current-health check. To run the Arc
and SRE halves from one page, also pass the SRE guide when you generate it
([one page for the whole demo](runbook.md#one-page-for-the-whole-demo-optional))
and open **`.local/full-demo-runsheet.md`** instead.

The guide is one story, the Monday-morning questions, in seven chapters (25-28 minutes
for the Arc path, with 20 and 15 minute cut lists) that follows one SQL database from
the estate list to the alert that starts the SRE half. The **Capacity and headroom**
and **Optimisation opportunities** workbooks are chapters 5 and 6 when their published
IDs are recorded; read the [workbook reference](operational-workbooks.md) first. Start
with the tiles and the evidence column, and with stale/missing evidence while hosts
are parked; gaps are not spare capacity or realised savings. The SQL and LOB incident
evidence continues in the SRE guide.

## Build and operate (the deploy path)

Start with the [runbook](runbook.md); your AI tool reads [AGENTS.md](../AGENTS.md)
first. To build the whole estate from zero, use the plan-first
[ordered build wrapper](runbook.md#build-everything-in-order-optional-wrapper); it
only runs the maintained scripts and plans only until you pass `-Execute`.

| Reference | Use |
| --- | --- |
| [Arc runbook](runbook.md) | Base infrastructure, ordered build, optional workbooks and presenter context |
| [Private build folder](private-config.md) | The one private folder, and the [setup block](private-config.md#set-up-the-whole-demo) that creates it with the skins and build config for the whole demo |
| [Nested SQL demo runbook](nested-sql-demo.md) | Parent preparation, guest ownership tags, proven scratch build, park, wake and remove; Jumpstart alternative |
| [Lifecycle](lifecycle.md) | Explicit targets, retained data, config-driven nested guest, readiness and measured shared-wait park/wake limits |
| [Troubleshooting](troubleshooting.md) | Practical build/wake failures and fixes |
| [Capacity and optimisation workbooks](operational-workbooks.md) | What each optional engineer workbook shows, its evidence rules, thresholds and guardrails |
| [Cost](cost.md) | Selected-workload estimates and retained charges |

The scratch nested Windows/SQL path is primary. The prebuilt Jumpstart image
remains a documented alternative with manual licence/OOBE, password and network
steps; see the [side-by-side results](nested-sql-demo.md#alternative-jumpstart-prebuilt-image).
Use the same private skin for build and lifecycle; do not rotate credentials,
reset faults or run destructive rehearsals incidentally.

## Optional scenarios

- [Real SQL workload on the simulated estate](sql-engine-workload.md):
  actual engine/transaction evidence, a live bounded lock-timeout/Sev2/automatic
  Review investigation rehearsal and capture limits, live-verified operational
  event v2/alert routing and guarded emitter update; separate from nested Arc SQL.
- [LOB sample](../samples/lob-arc-app/README.md): bounded warning and representative
  follow-up, original-worker restoration and automatic-investigation limitations.
- [Container App](container-app-fault.md): the app the SRE half investigates. The whole-demo
  build deploys it; an Arc-only build leaves it out.
- [AKS](aks-break-scenario.md): a separately prepared scenario.

SRE is optional and covers its investigations in the companion repo
[sre-agent-demo](https://github.com/corey-skapin/sre-agent-demo), where you
click Approve on the Review card in the SRE portal. Do not deploy its alerts or
rehearse faults as part of SQL setup.

## Configuration and reference

- [Reskin guide](reskin-guide.md): the private skin fields.
- [Fleet schema](legacy-os-fleet.md): `onPremFleet` / `-OnPremFleetPath` entries
  (the page name is historical; the schema is current).
- [Architecture](architecture.md): what Deploy creates and how it is wired.
- [SQL support decision](sql-arc-spike.md): what this lab can and cannot claim
  about SQL Server enabled by Azure Arc.
- [Workbook sources](../workbooks/arc-demo-overview.workbook.json) and
  [upstream attribution](../workbooks/nseilaz/README.md).

## Engineering and historical evidence (not the deploy path)

Nothing here is needed to build or operate the lab. Dated rehearsal results quoted
in any page, including the runbook, lifecycle and troubleshooting, record one
occasion; they are not current health.

- [Module map](module-map.md): maintained scripts, templates and tests, with the
  evidence behind them. [CONTRIBUTING](../CONTRIBUTING.md) covers the checks to
  run before a change.
