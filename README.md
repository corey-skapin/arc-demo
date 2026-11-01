# Azure Arc demo

Show how Arc and Azure Monitor turn a Windows/Linux server estate into one
operational view: identity, telemetry, application activity, alerts and posture.
This repo owns the **Arc part**; the optional companion repo owns the SRE part.

## Present

Open **`.local/presenter-runsheet.md`** in Markdown preview and go top to bottom.
It contains the prepared lab's portal links and copyable KQL. No input cards,
subscription-ID substitution, customer skins or second presentation guide.

If that file is missing, ask the preparing assistant/operator to
[generate it from the saved setup context](docs/runbook.md#prepare-the-local-presenter-guide).
The [tracked guide](docs/runsheet.md) is its source template.
Generation is offline; it does not activate the lab or certify current readiness.

The read-only story takes 20-30 minutes:
**estate workbook -> Arc identity -> fresh telemetry -> change/Linux signals ->
healthy LOB activity when prepared -> alert routing -> operating posture**.
The generated guide links to the optional SRE guide only when its local file
exists. Leave the lab unchanged at the end.

## What the lab contains

- Five Windows Server 2016/2019/2022 and three Ubuntu 22.04 hosts by default.
- Azure-hosted Arc simulation using `MSFT_ARC_TEST=true`, not production
  on-premises infrastructure or blanket support validation.
- Arc identities, workspace, DCRs, workbooks, alerts, Change Tracking,
  VM Insights, Update Manager and security/governance configuration.
- Optional LOB sample, [real SQL workload](docs/sql-engine-workload.md),
  Azure-native VM, Container App and AKS. Source presence does not prove installation/health.
- Optional [nested SQL/Arc demo](docs/nested-sql-demo.md): proven scratch Windows
  guest build, SQL Developer, Arc connection and config-driven park/wake/remove.

SQL preparation is separate and optional; the base Azure-VM simulation keeps
Arc SQL/BPA off. The genuine nested guest has its own explicit extension step.
Linux dependency mapping is off.
Monitor readiness does not establish active antivirus, full EDR, patch completion
or application health. See [support boundaries](docs/lifecycle.md).

## Operate, don't improvise

| Need | Reference |
|---|---|
| Build, prepare the presenter guide, or operate an existing lab | [Runbook](docs/runbook.md) |
| Build, park, wake or remove the nested SQL guest | [Short nested SQL runbook](docs/nested-sql-demo.md) |
| Activate, park, remove, retry or understand readiness | [Lifecycle contract](docs/lifecycle.md) |
| Investigate a symptom | [Troubleshooting](docs/troubleshooting.md) |
| Costs and retained charges | [Cost reference](docs/cost.md) |
| Engineering/support/optional scenarios | [Documentation index](docs/README.md) |

| State | Cost stance | Retained | Transition |
|---|---|---|---|
| **Active** | Reprice the selected workloads | All resources | Normal operating state; `Ready` is its compatibility alias |
| **Hibernated** | Storage, monitoring and other retained charges remain | Disks, identities, Arc/Monitor configuration and data | Compute parked; NAT/PIP removed only when safe |
| **Removed** | Verify final charges and exceptions | Shared/tenant/soft-deleted items as documented | Both demo groups and named policies/budget removed |

Lifecycle changes require separate approval and explicit subscription/tenant.
Park the companion first; wake Arc to Ready before the companion.
Do not reset faults or rotate retained credentials to make a tour look healthy.
Deployment configuration remains supported in the operator references; presenters
do not need to reskin or redeploy anything.

## Develop

Agents read [AGENTS.md](AGENTS.md) first. Use
[CONTRIBUTING.md](CONTRIBUTING.md) and [the module map](docs/module-map.md).
Private context and generated guides belong only in the gitignored `.local/`
folder; never store credentials or tokens there.

## Credits and licence

Inspired by [Nic Seilaz's](https://github.com/nseilaz) Arc/Monitor story.
The [vendored workbook library](workbooks/nseilaz/README.md) retains its upstream
attribution. MIT; see [LICENSE](LICENSE).
