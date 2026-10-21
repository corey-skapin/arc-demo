# AGENTS.md — AI Agent Operating Manual for `arc-demo`

> **This file is read first by AI coding agents** (GitHub Copilot CLI, Claude Code, Cursor, Windsurf, Aider, OpenAI Codex, etc.).
> Other AIs: also read this file before doing anything in this repo.
>
> Humans should follow [`README.md`](README.md) and [`docs/runbook.md`](docs/runbook.md).

---

## What this repo is

A scripted deployment of an **Azure Arc + Azure Monitor** demo environment. It stands up:

- 8 config-driven Azure VMs (Windows Server mix + Ubuntu 22.04 by default) that are then registered as **Arc-enabled servers** (using `MSFT_ARC_TEST=true` — see "Why we Arc-enable Azure VMs" below).
- 2 of the Windows VMs are SQL-capable hosts in the story. SQL Server 2022 Developer, Arc SQL registration, and BPA are skipped by default. Do not present Arc SQL as validated in this Azure-VM-backed lab; read `docs/sql-arc-spike.md` before touching `-InstallSql`.
- A Log Analytics workspace, Data Collection Rules, VM Insights and Change Tracking solutions for supported OS tiers only, Defender for Servers Plan 2, and a custom workbook modelled on a persona-first demo flow.
- Policy initiatives (MCSB + NIST SP 800-53 Rev 5) for the compliance scorecard tile.
- A scheduled query alert + Action Group → email for the "alert routing" demo tile.
- DevTest-Labs auto-shutdown at 19:00 local time for cost control.

**Cost:** Reprice selected workloads. The old active line items totalled AUD 358,
not 210, and their unit prices were unverified. Hibernation retains billable
storage/services; see `docs/cost.md`.

## Lifecycle safety and readiness

Read `docs/lifecycle.md` before operating an existing lab. All lifecycle commands
require explicit runtime `-SubscriptionId` and `-TenantId`; use the same
`-SkinPath`/prefix. Never store live IDs or secrets in source. Readiness is
`scripts\Test-ArcDemoReadiness.ps1 -DesiredState Ready|Hibernated -OutputFormat Json|Table`.
JSON schemaVersion 1 correlates exact resource IDs; exit 0 is pass, 1 failure/error,
2 pending. It never repairs or induces faults.

Monitor readiness does not certify endpoint protection. Approved Linux diagnostics
found healthy/licensed sensors in passive mode with real-time protection disabled;
extension-reported event-provider issues differed from direct sensor health.
Preserve these caveats. No AV-mode/policy change, extension retry/reinstall or
restart is authorized by a health inspection or a passing Monitor snapshot.

Keep the demo running unless the user explicitly approves parking/removal.
Read-only inspection and `-WhatIf` do not authorize mutation. No hibernate,
remove, credential reset, fault induction/reset, role or pricing changes as an
incidental test. Activation/hibernation preserve fault flags. Removal preserves
subscription Defender by default; `-DisableDefender` and
`-RemoveOnboardingIdentity` are explicit opt-ins.

For a combined demo, park the companion SRE layer through its own scripts before
Arc hibernation; reverse the dependency order when waking. Keep the runtime
target, skin/fleet inputs and deployment history outside git. Preview first and
verify `-DesiredState Hibernated` afterward; do not substitute permanent removal.

Lifecycle inventory uses retained successful per-workload deployment manifests:
an optional-only deployment with an empty fleet does not erase earlier VMs.
Classify OS using actual VM metadata, distinguish native/Arc/Monitor/patch
targets, and compare IDs, never counts or `win-*` naming. Missing/ambiguous
resources and mandatory wait/job/CLI failures must stop with actionable errors.

Activation must verify guests on retries, not skip a previously failed phase
because the VMs/Arc records now look running/connected. Windows Arc AMA is checked
through `MonAgentCore`, not an assumed `AzureMonitorAgent` SCM service. Restart
only real required services where needed; do not restart the extension host.
Default patch submissions run for retained Arc targets on every activation;
submission is not completion. Preserve optional `-ResultPath` evidence outside
git, and do not equate Monitor Ready with successful full-script completion.

## Mandatory pre-flight checks

Before running **any** deployment command, the agent MUST:

1. **Verify the explicitly targeted subscription and tenant.** Use `az account show --subscription <SUB>` and confirm the tenant matches runtime input. Every resource command must carry that target; do not trust or silently switch CLI defaults.
2. **Verify effective subscription Owner, or Contributor plus User Access Administrator**, including inherited/group assignments. A supplied principal ID does not bypass authorization checks.
3. **Verify PowerShell 7.4+, Az CLI 2.60+, and Bicep CLI are installed.** The scripts have a `Test-Prerequisites` function in `scripts/lib/Common.psm1` — call it first.
4. **Verify SKU restrictions and regional/family vCPU quota for the requested fleet.** Listings, what-if and `--validate` are not physical capacity guarantees. Do not create probe resources or register providers without approval. Read-only preflight fails if required providers (including DevTestLab and optional AKS dependencies) are not already registered.

If any check fails, **stop and tell the user** rather than continuing with workarounds.

## The 6 gotchas (these will bite you)

These are *not* hypothetical. Every one of them broke the original build. The scripts in this repo work around them — **do not rip out the workarounds**.

1. **Do not rely on default outbound.** Fresh Bicep deployment creates explicit NAT/PIP before VM extension provisioning and preserves an existing demo NAT on redeploy. `Hibernate-ArcDemo.ps1` intentionally **deletes** the NAT Gateway when parking, and **`Activate-ArcDemo.ps1` recreates it** before VM startup. Do not "optimise" this away.

2. **The Linux Arc GC extension stack is unreliable on Ubuntu 22.04 + `MSFT_ARC_TEST=true` in this lab.** AMA and ChangeTracking-Linux use the Azure VM extension path (`az vm extension set`); DCRAs still target Arc IDs. Read-only evidence found stuck Arc extensions; approved VM-path CT installation produced guest success and fresh CT telemetry without reboot. Do not delete stuck Arc extensions without separate approval. Linux Dependency Agent/VM Insights map is intentionally disabled, not installed via either path. Windows uses Arc extensions. See the official CT support matrix linked in `docs/lifecycle.md`; generic support is not lab validation.

3. **DCR associations must target the Arc HybridCompute resource ID, not the Azure VM resource ID,** *even when* you installed the agent via the Azure VM extension path. When the Linux AMA detects the Arc agent, it pulls config from Arc IMDS, which only sees DCR associations attached to the Arc resource. If you don't see Heartbeat in Log Analytics, this is why.

4. **`Standard_B2s` / `Standard_B2ms` have been capacity-restricted** in AU lab subscriptions. The default is `Standard_B2as_v2` (2 vCPU / 8 GiB AMD burstable). Check SKU restrictions/quota, retain a prep window, and never claim allocation is guaranteed.

5. **Azure CLI on Windows mangles URLs containing `?` and `()`.** PowerShell shells out to `cmd.exe`, which treats `?` as a wildcard and `()` as grouping. This affects any `az rest --url` call where the URL contains `?api-version=...` AND a parenthesised resource name (the OMS Solutions API does both, e.g. `solutions/VMInsights(law-name)?api-version=...`). **The repo uses native `Invoke-RestMethod` with an `az account get-access-token` bearer token in these cases.** Do not switch them back to `az rest`.

6. **The Azure CLI's `az policy assignment create` and `az monitor data-collection rule create --rule-file` are buggy** with the payloads the demo needs. The repo uses `Invoke-RestMethod` (PUT) directly for those resources. Do not switch them to `az`.

## Code style & conventions

- **PowerShell scripts** use approved verbs (`Verb-Noun.ps1`), parameter validation attributes, `CmdletBinding(SupportsShouldProcess)`, write to `$VerbosePreference`-aware streams, and emit structured objects, never `Write-Host` (except for top-level progress banners). PSScriptAnalyzer is enforced via `.github/workflows/lint.yml`.
- **Bicep modules** in `bicep/modules/`, top-level template in `bicep/main.bicep`. Always `az bicep build` before commit.
- **Don't introduce new top-level dependencies.** This repo intentionally uses only `az`, `pwsh 7+`, and `Invoke-RestMethod` (built into PS). Adding Terraform / Pulumi / `Az` PowerShell module / etc. is out of scope.
- **Idempotency is mandatory.** Preserve existing VM/SP credentials; do not reset demo faults during lifecycle operations. Mock reruns locally. Double deployment and destructive live lifecycle tests require approval in a disposable lab; do not run them against an in-use demo. Targeted VM startup/readiness proof is not proof of the full activation script, which can restart guest agents and submit patch assessments.

## Happy-path command sequence

```powershell
# 1. Clone & cd
git clone <ARC_REPOSITORY_URL> C:\src\arc-demo
cd C:\src\arc-demo

# 2. Sign in to the target tenant
az login --tenant <TENANT_ID>
az account set --subscription <SUBSCRIPTION_ID>

# 3. Verify prereqs
.\scripts\Test-Prerequisites.ps1 -SubscriptionId <SUB> -TenantId <TENANT>

# 4. Deploy
.\scripts\Deploy-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -AdminEmail <OPERATOR_EMAIL>

# 5. After the demo, hibernate
.\scripts\Hibernate-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT>

# 6. Before the next demo, activate
.\scripts\Activate-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT>
.\scripts\Test-ArcDemoReadiness.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -OutputFormat Json

# 7. When done permanently
.\scripts\Remove-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT>
```

## Things this repo intentionally does NOT do

If asked to add any of the following, push back first and confirm:

- **Production-grade hardening** (managed identities everywhere, private endpoints for LAW, Just-in-Time VM access, KV firewall, NSG inbound rules). This is a *demo lab*, not a production reference.
- **VM image hardening / CIS benchmarks.** The whole point of the demo is to show *un-hardened* machines with vulnerabilities for Defender to flag.
- **Multi-region / HA.** Single region, single LAW.
- **Real ServiceNow / PagerDuty integration.** The Action Group is configured for email + has a documented one-liner to add a webhook later.
- **Bicep-only deployment.** Some steps (Arc onboarding via Run Command, agent restart, post-deploy validation) are imperative by nature. The Bicep template handles the static infra; the PowerShell wrapper drives the imperative bits. This split is deliberate.

## Why we Arc-enable Azure VMs (for the AI's understanding)

Arc is for non-Azure compute. This demo uses Azure VMs that *act* like on-prem
servers, without an on-prem hypervisor. `MSFT_ARC_TEST=true` bypasses the installer's
Azure-VM guard for test/demo simulation. See the [Microsoft Learn warning](https://aka.ms/azcmagent-testwarning).
This is not a production pattern or blanket validation of Arc extensions, Arc SQL
or other features on Azure VMs; use the workload-specific evidence and limitations
in `docs/lifecycle.md`.

## Validation & testing

Run local checks before pushing. Live smoke tests below are a separate,
explicitly approved disposable-lab exercise, not routine validation:

```powershell
# Lint
Invoke-ScriptAnalyzer -Path .\scripts\ -Recurse -Severity Warning
Invoke-Pester -Path .\tests -CI

# Bicep build
az bicep build --file .\bicep\main.bicep --stdout > $null

# Dry-run deploy (validates Bicep + checks RBAC, no resources created)
.\scripts\Deploy-ArcDemo.ps1 -WhatIf -SubscriptionId <SUB> -TenantId <TENANT> -AdminEmail <OPERATOR_EMAIL>

# Full smoke test cycle (~45 min total). Run manually with prefix "arctest":
.\scripts\Deploy-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -AdminEmail <OPERATOR_EMAIL> -NamePrefix arctest
.\scripts\Hibernate-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -NamePrefix arctest
.\scripts\Activate-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -NamePrefix arctest
.\scripts\Remove-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -NamePrefix arctest
```

## When something breaks

The first place to look is [`docs/troubleshooting.md`](docs/troubleshooting.md) — every failure mode I've personally hit is documented there with a verified fix.

If the user reports an issue that isn't in `troubleshooting.md`, **add it** as part of the same change.
