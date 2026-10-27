# Arc documentation

## Present the demo

Open **`.local/presenter-runsheet.md`** from the repo root and follow it top to
bottom. All resource links and KQL are filled from the operator's saved local
context; no input card or ID hunting. [runsheet.md](runsheet.md) is the single
tracked source template, not an additional script to rehearse.

If the generated file is missing, the preparing assistant/operator follows
[this one-time setup](runbook.md#prepare-the-local-presenter-guide).
Generating it is offline and does not check or change Azure.
The operator must separately verify Active readiness before presenting.

Arc ends with an optional link to the companion's local SRE runsheet when that
file exists. SRE investigation/approval/scenarios belong in that repo, not here.

## Operator references

These are not presenter prerequisites:

| Reference | Use |
|---|---|
| [Runbook](runbook.md) | Build and operate the lab; generate/refresh local presenter context |
| [Lifecycle](lifecycle.md) | Consent, explicit targets, wake/park/remove, readiness and support limits |
| [Troubleshooting](troubleshooting.md) | A symptom you actually see; repair requires its own approval |
| [Cost](cost.md) | Reprice selected workloads; understand retained charges |
| [AI setup handoff](ai-deploy-handbook.md) | Give an assistant approved inputs and ask it to prepare the lab and local guide |

## Optional scenario and engineering references

- [LOB sample](../samples/lob-arc-app/README.md): healthy business events and
  source context; optional installation, not part of an Arc-only deployment.
- [Container App](container-app-fault.md), [AKS](aks-break-scenario.md),
  [SQL-shaped simulator](sql-workload-simulation.md): separate optional scenarios;
  no live faults or resets without approval.
- [SQL support decision](sql-arc-spike.md), [legacy OS support](legacy-os-fleet.md),
  [architecture](architecture.md): limits and background, not more presenter steps.
- [Module map](module-map.md): code ownership and dated non-presenter engineering
  evidence, never today's health.
- [Existing deployment configuration](reskin-guide.md): retained operator
  compatibility; do not make customization a prerequisite for presenting.
- [AGENTS](../AGENTS.md), [CONTRIBUTING](../CONTRIBUTING.md),
  [workbook sources](../workbooks/arc-demo-overview.workbook.json) and
  [upstream workbook attribution](../workbooks/nseilaz/README.md): development.
