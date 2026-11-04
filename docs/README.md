# Arc documentation

## Present the demo

Open **`.local/presenter-runsheet.md`** from the repo root and follow it top to
bottom. [runsheet.md](runsheet.md) is the single source template; the operator
[generates the guide](runbook.md#prepare-the-local-presenter-guide) from saved
local context. Generation is offline, not a current-health check. To run the Arc
and SRE halves from one page, the operator also passes the SRE guide
([one page for the whole demo](runbook.md#one-page-for-the-whole-demo-optional))
and you open **`.local/full-demo-runsheet.md`** instead.

The guide is one story, the Monday-morning questions, in seven chapters (25-28 minutes
for the Arc path, with 20 and 15 minute cut lists) that follows one SQL database from
the estate list to the alert that starts the SRE half. The **Capacity and headroom**
and **Optimisation opportunities** workbooks are chapters 5 and 6 when their published
IDs are recorded; read the [workbook reference](operational-workbooks.md) first. Start
with the tiles and the evidence column, and with stale/missing evidence while hosts
are parked; gaps are not spare capacity or realised savings. The SQL and LOB incident
evidence is handed to the SRE guide.

## Build and operate (the deploy path)

Read [AGENTS.md](../AGENTS.md) first, then the [runbook](runbook.md). To build the
whole estate from zero, use the plan-first
[ordered build wrapper](runbook.md#build-everything-in-order-optional-wrapper); it
only runs the maintained scripts and needs no approval until `-Execute`.

| Reference | Use |
| --- | --- |
| [AI handoff](ai-deploy-handbook.md) | Ask an assistant to prepare the demo |
| [Arc runbook](runbook.md) | Base infrastructure, ordered build, optional workbooks and presenter context |
| [Private build folder](private-config.md) | The one private folder: build config, state and evidence |
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
- [Container App](container-app-fault.md) and [AKS](aks-break-scenario.md):
  separately prepared scenarios.

SRE is optional and owns its investigations and human Review approvals in the
companion repo. Do not deploy its alerts or rehearse faults as part of SQL setup.

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
- [SQL-shaped simulator](sql-workload-simulation.md): the retired events-only
  simulator (`scripts/Invoke-SqlWorkloadOnArc.ps1`), kept for reference; it is not
  engine proof and no build step runs it.
