# Agent instructions for arc-demo

## Read first

- Read this file before working in the repository.
- Start humans at [docs/README.md](docs/README.md); present the generated `.local/presenter-runsheet.md` from the single [runsheet template](docs/runsheet.md).
- Read [runbook](docs/runbook.md) and [lifecycle](docs/lifecycle.md) before operating an existing lab.
- Use [troubleshooting](docs/troubleshooting.md) for symptoms and [module map](docs/module-map.md) for engineering evidence; do not treat old runs as current health.

## Keep the demo scope

- Keep the single-region, intentionally un-hardened Arc/Monitor demo and its 20-30 minute story.
- Explain Azure-hosted Arc simulation using `MSFT_ARC_TEST=true`; do not present it as a production pattern or blanket feature validation.
- Keep SQL optional. The base Azure-VM simulation keeps Arc SQL/BPA off; the mixed `-InstallSql` path is retired. For genuine nested Windows/SQL/Arc, use the [scratch demo runbook](docs/nested-sql-demo.md) and its proven scripts. The Jumpstart image is a manual alternative. Never present simulated events as engine proof.
- SQL incident rehearsal uses only the owned bounded probe/session rollback and exact-host Sev2 alert; preserve the orders worker. Verify the SQL-extension-only local block before install, leave existing policy/monitoring intact, and keep the companion's automatic investigation Review-only. Never kill historical session IDs or run a probe as readiness/lifecycle preparation.
- Distinguish blocked Arc SQL ARM attempts from independently policy-deployed Defender for SQL. Retain required security; no sensor removal/block, discovery falsification or plan/policy change to clear demo drift. Any host-only policy exception needs the responsible owner's review and separate approval.
- Confirm before adding production hardening, CIS images, multi-region/HA, real ITSM integrations or a Bicep-only redesign.
- Keep static infrastructure in Bicep and necessary onboarding/validation in PowerShell; add no framework or top-level dependency beyond `az`, PowerShell and built-in REST.
- Reprice selected workloads using [cost.md](docs/cost.md); never promise a fixed all-in bill or zero-cost parking.
- Keep optional capacity/optimisation workbooks evidence-first: exact Arc IDs, missing/stale/history warnings, declared parent/guest separation with no hardware totals, no CPU-only sizing or billed/realised savings. Preview is not publication permission; do not expand collection, activate hosts or induce faults to populate a tile. Use [the scoped workbook procedure](docs/runbook.md#optional-capacity-and-optimisation-workbooks); DR and Azure Migrate assessment are excluded.

## Target and consent

- Require explicit runtime `-SubscriptionId` and `-TenantId`; verify that exact context without silently switching CLI defaults.
- Keep the same confirmed prefix/skin/fleet; store targets, credentials, hashes, manifests and dated evidence privately outside git.
- Preview with normal lifecycle `-WhatIf`; never treat preview or read-only inspection as permission to mutate.
- Obtain explicit approval for activation, hibernation, removal, faults/reset, assessments, alert tests/emails, repair, credential, role or pricing changes.
- Keep the lab running unless parking/removal is requested; never exercise a live lifecycle incidentally during testing.
- Surface denied/malformed/unknown reads and actual CLI/job failures; never substitute absence or bypass a denial with another tool.
- Preserve credentials, workload fault flags, disks/data, identities, RBAC, logs and private vault access on routine lifecycle/reconcile.
- Never rotate a retained VM/onboarding credential for convenience; follow the existing-secret contract in lifecycle.md.
- Keep guest passwords and onboarding credentials private and reuse them on wake. Private onboarding initialization is separate setup, not lifecycle preparation; never open a private vault or rotate an existing key to clear a failure.
- Define the nested guest once in `nestedSqlGuest` in the private skin. Activate starts the parent then guest; Hibernate gracefully stops the guest then parks compute; Remove uses the same configuration. Do not add parallel manifest/tuple/review workflows for the demo.

## Park, wake and remove

- Keep Active, Hibernated and Removed; retain Ready as the Active compatibility alias/default.
- Use normal lifecycle context/ownership/ShouldProcess, not deployment Graph/Owner/provider/quota or historical whole-group index gates.
- Fail open for spend-reducing Hibernate: park all compute in the explicitly targeted `rg-<prefix>-infra`, warning manifest/OS/skin drift.
- Require an explicit confirmed prefix if parking without a readable skin; do not guess the target.
- Attempt other demo workloads after an individual stop fails; require known VM deallocation, AKS Stopped/Succeeded and inactive app revisions afterward.
- Report denied/unknown compute state as error/nonzero, never verified stopped compute.
- Deactivate Container App revisions; do not substitute zero minimum replicas or reset fault flags.
- Verify exclusive NAT/PIP bindings before network writes; skip unsafe cleanup loudly, not compute parking.
- Preserve compute-stop -> subnet detach -> NAT delete -> PIP delete order; disclose retained-network cost diagnostics even on exit 0.
- Keep retained monitoring out of Hibernated gates; run Active readiness again before the next demo.
- Fail closed for Activate VM selection, Deploy and Remove; retain strict manifests, skin checks, exact IDs and actual OS metadata, not counts/name heuristics.
- Retain earlier fleet manifests after optional empty-fleet deployments; never start an unknown/unlisted VM.
- Restore explicit NAT/PIP before starting compute; never rely on default outbound or remove the park/wake NAT workaround.
- Wait for in-flight VM/AKS transitions rather than resubmitting; keep bounded waits and partial progress on failure.
- Preserve VM definitions/NICs/disks/Arc identities while parked; never delete/reconstruct VMs as a cost shortcut.
- Managed Run Command is limited to 25 saved commands per VM. Preserve useful failures; remove only completed demo-owned commands through the working helper, not unrelated commands or an in-flight operation.
- Keep Defender pricing unchanged on default removal; require separate `-DisableDefender` / `-RemoveOnboardingIdentity` consent.
- Verify both groups and named subscription policies/budget absent for Removed; disclose tenant/shared/soft-delete exceptions without purging or claiming zero bill.

## Activation and readiness

- Verify guests on every activation/retry, including already-running/connected hosts; do not restart already-correct hosts or skip a failed phase.
- Submit host checks concurrently through existing checked jobs and retain per-host `-ResultPath` evidence outside git.
- Check Windows Arc `himds` and AMA `MonAgentCore`, not an assumed `AzureMonitorAgent` SCM service; never restart the extension host.
- Allow the ten-minute AMA startup wait and explicit pending marker; preserve true service/command failures and safe completion-marker checks.
- Check Linux services individually; remove temporary script files/jobs on success and failure without exposing arbitrary guest output.
- Submit default patch assessments only for Arc hosts started/waking on this attempt; do not resubmit on already-active retries.
- Use `-AssessPatches` only for explicit all-host assessment work; reject it with `-SkipPatchAssessment`, and distinguish submission from completion.
- Record telemetry-only lag as pending even when activation exits 0; poll read-only readiness to pass before presentation or dependent SRE/incident offers.
- After successful preparation, save only approved nonsecret presenter context in `.local/demo-context.json` and run `New-PresenterRunsheet.ps1`; hand over `.local/presenter-runsheet.md`, not an input card, and keep deployment configuration out of the tour.
- Do not report `-SkipValidate`, a rolling Heartbeat boolean or a Monitor snapshot as proof of full-script completion or fresh post-wake telemetry.
- Use `Test-ArcDemoReadiness.ps1 -DesiredState Active|Ready|Hibernated|Removed -OutputFormat Json|Table`; honor required flags and schema v1 exits 0/pass, 1/fail-error, 2/pending.
- Keep readiness read-only with bounded `TimeoutSeconds`; never repair or induce faults to make it green.
- Do not equate Monitor readiness with patch completion, policy compliance, CT inventory, active AV or full EDR/event delivery.

## Combined Arc and companion SRE

- Park the companion through its own scripts first; wake Arc/Monitor to Ready before resuming SRE/config/application readiness.
- Preserve the companion's retained identity/RBAC and Review-only human approval boundary; let its own scripts delete the paid parent on parking.
- For combined activation, let the SRE-owning AI make one conversational incident offer after readiness, using `../sre-agent/docs/ai-deploy-handbook.md#post-activation-incident-offer` from this repo root (skip if the companion repo is not present).
- Treat activation alone as no incident consent; leave active if declined, and use only the established T09 observation/recovery flow if accepted.
- Keep actual human Review approval; never invent approval or make the user choose scripts/execute a command list.
- Never prompt for or induce an incident after Arc-only activation; add no script/orchestrator incident prompt or duplicate offer.

## Preserve platform workarounds

- Install Linux AMA and ChangeTracking through the Azure VM extension path in this lab; keep Windows on Arc extensions.
- Keep DCR associations on Arc resource IDs for simulated Arc hosts, even with VM-path agents; use VM IDs for native hosts.
- Keep Linux Dependency Agent/VM Insights map disabled; honor supported OS/capability flags and [CT guidance](docs/lifecycle.md#linux-monitoring-and-support-stance).
- Do not delete stuck Arc extensions or change AV mode/policy/reinstall/restart from a health inspection; preserve direct-sensor versus extension caveats.
- Keep native `Invoke-RestMethod` for OMS solution URLs containing `?`/parentheses and for policy assignments/DCR PUTs; do not switch back to the buggy CLI paths.
- Keep fresh OS disks Standard SSD; preserve existing HDD with explicit `Standard_LRS` and the retained-tier guard, never incidental conversion.
- Plan HDD OS migration separately before 8 September 2028; do not call an already-HDD estate's avoided SSD cost new savings.

## Deployment preflight only

1. Verify the explicitly requested tenant/subscription and effective inherited/group Owner, or Contributor plus User Access Administrator; do not bypass permissions with a supplied principal ID.
2. Run `Test-Prerequisites` for PowerShell 7.4+, CLI 2.60+ and Bicep; stop on failure rather than workaround.
3. Check needed providers, including DevTestLab and optional AKS dependencies; obtain approval separately for registration.
4. Check exact SKU restrictions and regional/family vCPU quota; never claim listings, what-if or validation guarantee allocation, especially B-series in AU regions.

## Code, tests and documentation

- Use approved PowerShell verbs, validation attributes, ShouldProcess, structured objects and preference-aware streams; reserve Write-Host for progress banners.
- Keep Bicep modules under `bicep/modules` and the entry template at `bicep/main.bicep`.
- Preserve idempotency; use local mocked reruns, not an in-use lab's double deployment or destructive lifecycle cycle.
- Run Pester, script parsing, PSScriptAnalyzer, `az bicep build` and Markdown lint before pushing; keep test-only dependencies out of deployment requirements.
- Propose disposable live smoke scope/cost separately and obtain approval before execution; distinguish mocks, prior operational evidence and new live proof.
- Scan changed tracked content for secrets/private identifiers before every push; keep real GUIDs, emails, customer names and machine-local paths out of source.
- Update the canonical docs with behavior, index changes in docs/README.md and keep the module map current; add no competing runsheet or tracking diary.
- Ground portal steps in current Microsoft Learn and distinguish documented navigation from observed UI; default beginner rehearsals to read-only evidence.
- Add newly reported symptoms to troubleshooting with established causes/limits, not invented diagnoses or implicit repair permission.
