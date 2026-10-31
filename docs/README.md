# Arc documentation

## Present the demo

Open **`.local/presenter-runsheet.md`** from the repo root and follow it top to
bottom. [runsheet.md](runsheet.md) is the single source template; the operator
[generates the guide](runbook.md#prepare-the-local-presenter-guide) from saved
local context. Generation is offline, not a current-health check.

The **Optional engineer lens** links to **Capacity and headroom** and
**Optimisation opportunities** when their published IDs are recorded. Start
with stale/missing evidence while hosts are parked; gaps are not spare capacity
or realised savings. The Arc/Monitor story remains 20-30 minutes.

## Build and operate

| Reference | Use |
|---|---|
| [Nested SQL demo runbook](nested-sql-demo.md) | Proven scratch build, park, wake and remove; Jumpstart alternative |
| [Arc runbook](runbook.md) | Base infrastructure, optional workbooks and presenter context |
| [Lifecycle](lifecycle.md) | Explicit targets, retained data, config-driven nested guest and readiness |
| [Troubleshooting](troubleshooting.md) | Practical build/wake failures and fixes |
| [AI handoff](ai-deploy-handbook.md) | Ask an assistant to prepare the demo |
| [Cost](cost.md) | Selected-workload estimates and retained charges |
| [Module map](module-map.md) | Maintained scripts, templates and tests |

The scratch nested Windows/SQL path is primary. The prebuilt Jumpstart image
remains a documented alternative with manual licence/OOBE, password and network
steps; see the [side-by-side results](sql-arc-spike.md#nested-sql-demo-prototype-race).
Use the same private skin for build and lifecycle; do not rotate credentials,
reset faults or run destructive rehearsals incidentally.

## Optional scenarios and background

- [Real SQL workload on the simulated estate](sql-engine-workload.md):
  actual engine/transaction evidence, separate from the nested Arc SQL path.
- [LOB sample](../samples/lob-arc-app/README.md), [Container App](container-app-fault.md)
  and [AKS](aks-break-scenario.md): separately prepared scenarios.
- [SQL support decision](sql-arc-spike.md), [SQL-shaped simulator](sql-workload-simulation.md),
  [legacy OS](legacy-os-fleet.md) and [architecture](architecture.md): honest limits.
- [Reskin guide](reskin-guide.md), [AGENTS](../AGENTS.md) and
  [CONTRIBUTING](../CONTRIBUTING.md): operator/developer references.
- [Workbook sources](../workbooks/arc-demo-overview.workbook.json) and
  [upstream attribution](../workbooks/nseilaz/README.md).

SRE is optional and owns its investigations and human Review approvals in the
companion repo. Do not deploy its alerts or rehearse faults as part of SQL setup.
