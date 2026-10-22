# Documentation: start here

**Presenting an existing demo? Read this page, then [runsheet.md](runsheet.md).**
You do not need to read every document or deploy anything to present it.
The runsheet is the single canonical Arc/Monitor presenter guide: preparation,
one practice pass, timed clicks, expected results, talk track and fallbacks.

## Minimal ordered presenter path

1. Read the scope and private input card in [the runsheet](runsheet.md#before-you-start).
   Obtain an already-deployed lab and access from its operator. Never replace
   an existing lab's private inputs with bundled synthetic examples.
2. Complete [preparation and one rehearsal](runsheet.md#prepare-and-practise-once).
   Bookmark the actual workbook, workspace, Arc machine and alert resources.
   If the lab is parked, the operator uses [lifecycle.md](lifecycle.md) under
   separate approval; presenting is not permission to activate it.
3. Present [the timed Arc walkthrough](runsheet.md#present-the-arcmonitor-demo).
   The core is workbook -> telemetry/diagnosis -> alert/routing -> Arc identity.
   Add patch/security/governance beats for the full 20-30 minute conversation.
4. For a combined demo, continue at [the SRE handoff](runsheet.md#optional-sre-handoff).
   Use the companion repository's `docs\delivery-runsheet.md`, starting at its
   post-Arc handoff. Its `docs\README.md` explains its own optional scenarios.
   Arc alone does not need SRE, a Logic App, AKS or SQL.

Keep this index and the runsheet open while practising. Use
[troubleshooting.md](troubleshooting.md) only for a symptom you actually see.
Deployment and repair instructions below are for the operator, not extra
presenter prerequisites.

## Every document in this folder

**Canonical** means the maintained procedure for that activity, not that
everyone must read it. **Reference** explains implementation or limits.
**Optional** is outside the default live flow and does not prove deployment.
There are no archived/obsolete files in this folder; historical observations
inside reference documents are dated evidence, not current health guarantees.

| Document | Audience and purpose | Status / when to read |
|---|---|---|
| [README.md](README.md) | All readers: choose the right documents and presenter order. | Canonical documentation index; start here. |
| [runsheet.md](runsheet.md) | First-time presenter: private input card, rehearsal, exact navigation, evidence, words to say, timing and fallbacks. | Canonical presentation guide; required for presenting. |
| [runbook.md](runbook.md) | Lab operator: prerequisite checks, preview, deployment and ongoing operations. | Canonical build/operations procedure; not a second runsheet. |
| [lifecycle.md](lifecycle.md) | Operator/integrator: strict wake/delete ownership, best-effort parking, concurrent cold starts, readiness JSON and validation limits. | Canonical lifecycle/readiness contract; required before operating the lab, not for a read-only tour. |
| [troubleshooting.md](troubleshooting.md) | Operator: symptom-specific evidence, known fixes and unresolved limitations. | Reference; repair commands need scoped approval. |
| [architecture.md](architecture.md) | Presenter needing background, architect or maintainer: topology, identity, data flow and optional components. | Reference; useful before rehearsal, not a live script. |
| [cost.md](cost.md) | Operator/budget owner: dated retail assumptions, actual observed footprint, HDD choice/retirement and active versus parked costs. | Reference; no fixed all-in bill or implicit authorization to resize. |
| [reskin-guide.md](reskin-guide.md) | Operator preparing a different lab: private configuration, labels, fleet and retained-tier inputs. | Canonical customization procedure; unnecessary for an existing lab tour. |
| [legacy-os-fleet.md](legacy-os-fleet.md) | Operator/architect: fleet schema, support gates and represented-not-running legacy tiers. | Reference; default live fleet does not include every example OS. |
| [module-map.md](module-map.md) | Maintainer: which Bicep module, script/helper, workbook and test owns each behavior. | Reference; not presenter reading. |
| [ai-deploy-handbook.md](ai-deploy-handbook.md) | Operator delegating an approved build to an assistant: prompt, inputs and checks. | Optional operator aid; runbook/lifecycle remain canonical. |
| [container-app-fault.md](container-app-fault.md) | Scenario operator: optional app, restart alert and separately approved break/reset verification. | Optional scenario procedure; inspect existing evidence during the default tour. |
| [aks-break-scenario.md](aks-break-scenario.md) | Scenario operator: optional AKS workload, crash-loop alert and break/reset commands. | Optional scenario procedure; absent from the verified eight-host lab, not a default prerequisite. |
| [sql-workload-simulation.md](sql-workload-simulation.md) | Scenario operator/DBA: optional SQL-shaped Application events, not a SQL engine or Arc SQL validation. | Optional simulator procedure; source presence is not proof it is installed. |
| [sql-arc-spike.md](sql-arc-spike.md) | Architect/DBA: decision record separating workload simulation from supported Arc SQL on a real non-Azure host. | Reference/support boundary; do not follow its separate-lab install example in this Azure-only demo. |

## Related entry points outside this folder

| Entry point | Use |
|---|---|
| [Repository README](../README.md) | Product overview and quick start; routes presenters here. |
| [AGENTS.md](../AGENTS.md) and [CLAUDE.md](../CLAUDE.md) | Coding-agent operating rules; not presenter guides. |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | Local development, validation and safe contribution rules. |
| [Workbook source](../workbooks/arc-demo-overview.workbook.json) | Defines the custom workbook's actual tile titles and queries. |
| [Vendored workbook library](../workbooks/nseilaz/README.md) | Optional additional workbooks and upstream attribution; not required screens. |
| [LOB sample](../samples/lob-arc-app/README.md) | Optional companion-SRE application/code-context sample; not installed by the Arc-only tour. |
| [SQL sample source](../samples/sql-workload/SqlWorkloadSimulator.ps1) | Simulator implementation; use the optional SQL procedure above for operations. |

## Keeping the story current

Update the canonical runsheet instead of creating another competing walkthrough.
Its [grounding ledger](runsheet.md#portal-grounding-and-observation-limits)
records current Microsoft sources, review date and what was or was not observed
in the portal. Check the chosen tenant's actual pages during rehearsal; do not
invent renamed blades or treat generic product documentation as proof of lab data.
Keep live IDs, recipients, URLs containing private resource IDs, screenshots and
timestamped readiness/activation results outside tracked source.
