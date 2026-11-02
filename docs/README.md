# Arc documentation

## Present the demo

Open **`.local/presenter-runsheet.md`** from the repo root and follow it top to
bottom. [runsheet.md](runsheet.md) is the single source template; the operator
[generates the guide](runbook.md#prepare-the-local-presenter-guide) from saved
local context. Generation is offline, not a current-health check.

The **Optional engineer lens** links to **Capacity and headroom** and
**Optimisation opportunities** when their published IDs are recorded; read the
[workbook reference](operational-workbooks.md) first. Start with the tiles and
the evidence column, and with stale/missing evidence while hosts are parked; gaps
are not spare capacity or realised savings. The Arc/Monitor story remains 20-30 minutes.

## Build and operate

| Reference | Use |
| --- | --- |
| [Nested SQL demo runbook](nested-sql-demo.md) | Parent preparation, guest ownership tags, proven scratch build, park, wake and remove; Jumpstart alternative |
| [Arc runbook](runbook.md) | Base infrastructure, optional workbooks and presenter context |
| [Ordered build wrapper](runbook.md#build-everything-in-order-optional-wrapper) | Plan-first build of the whole estate in order, plus read-only snapshot and parity |
| [Private build folder](private-config.md) | The one private folder: build config, state and evidence |
| [Capacity and optimisation workbooks](operational-workbooks.md) | What each optional engineer workbook shows, its evidence rules, thresholds and guardrails |
| [Lifecycle](lifecycle.md) | Explicit targets, retained data, config-driven nested guest, readiness and measured shared-wait park/wake limits |
| [Troubleshooting](troubleshooting.md) | Practical build/wake failures and fixes |
| [AI handoff](ai-deploy-handbook.md) | Ask an assistant to prepare the demo |
| [Cost](cost.md) | Selected-workload estimates and retained charges |
| [Module map](module-map.md) | Maintained scripts, templates and tests |

The scratch nested Windows/SQL path is primary. The prebuilt Jumpstart image
remains a documented alternative with manual licence/OOBE, password and network
steps; see the [side-by-side results](nested-sql-demo.md#alternative-jumpstart-prebuilt-image).
Use the same private skin for build and lifecycle; do not rotate credentials,
reset faults or run destructive rehearsals incidentally.

## Optional scenarios and background

- [Real SQL workload on the simulated estate](sql-engine-workload.md):
  actual engine/transaction evidence, a live bounded lock-timeout/Sev2/automatic
  Review investigation rehearsal and capture limits, live-verified operational
  event v2/alert routing and guarded emitter update; separate from nested Arc SQL.
- [LOB sample](../samples/lob-arc-app/README.md): bounded warning and representative
  follow-up, original-worker restoration and automatic-investigation limitations.
- [Container App](container-app-fault.md) and [AKS](aks-break-scenario.md):
  separately prepared scenarios.
- [SQL support decision](sql-arc-spike.md), [SQL-shaped simulator](sql-workload-simulation.md),
  [legacy OS](legacy-os-fleet.md) and [architecture](architecture.md): honest limits.
- [Reskin guide](reskin-guide.md), [AGENTS](../AGENTS.md) and
  [CONTRIBUTING](../CONTRIBUTING.md): operator/developer references.
- [Workbook sources](../workbooks/arc-demo-overview.workbook.json) and
  [upstream attribution](../workbooks/nseilaz/README.md).

SRE is optional and owns its investigations and human Review approvals in the
companion repo. Do not deploy its alerts or rehearse faults as part of SQL setup.
