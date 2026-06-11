# AGENTS.md — AI Agent Operating Manual for `arc-demo`

> **This file is read first by AI coding agents** (GitHub Copilot CLI, Claude Code, Cursor, Windsurf, Aider, OpenAI Codex, etc.).
> Other AIs: also read this file before doing anything in this repo.
>
> Humans should follow [`README.md`](README.md) and [`docs/runbook.md`](docs/runbook.md).

---

## What this repo is

A scripted deployment of an **Azure Arc + Azure Monitor** demo environment. It stands up:

- 8 Azure VMs (5 Windows Server 2022, 3 Ubuntu 22.04) that are then registered as **Arc-enabled servers** (using `MSFT_ARC_TEST=true` — see "Why we Arc-enable Azure VMs" below).
- 2 of the Windows VMs run SQL Server 2022 Developer, **Arc-enabled** for Best Practice Assessment.
- A Log Analytics workspace, Data Collection Rules, VM Insights and Change Tracking solutions, Defender for Servers Plan 2, and a custom workbook modelled on a persona-first demo flow.
- Policy initiatives (MCSB + NIST SP 800-53 Rev 5) for the compliance scorecard tile.
- A scheduled query alert + Action Group → email for the "alert routing" demo tile.
- DevTest-Labs auto-shutdown at 19:00 local time for cost control.

**Total active cost:** ~AUD 210/mo with nightly auto-shutdown.
**Hibernated cost:** ~AUD 35/mo.

## Mandatory pre-flight checks

Before running **any** deployment command, the agent MUST:

1. **Verify the active subscription is the intended demo subscription.** `az account show --query "{id:id,tenant:tenantId,user:user.name}" -o table` and confirm with the user if the values don't match `-SubscriptionId`/`-TenantId` parameters. **Do not just trust `az account show`**; the active subscription drifts back to a default when tokens expire.
2. **Verify the user has `Owner` role on the subscription.** Lesser roles will fail at policy assignment + role assignment time, halfway through a 30-min deploy.
3. **Verify PowerShell 7.4+, Az CLI 2.60+, and Bicep CLI are installed.** The scripts have a `Test-Prerequisites` function in `scripts/lib/Common.psm1` — call it first.
4. **Verify the requested SKU is available in the chosen region.** Skip with `--validate` — capacity restrictions on B-series in AU regions are common.

If any check fails, **stop and tell the user** rather than continuing with workarounds.

## The 6 gotchas (these will bite you)

These are *not* hypothetical. Every one of them broke the original build. The scripts in this repo work around them — **do not rip out the workarounds**.

1. **Default outbound is being deprecated.** New VMs created with `--public-ip-address ""` and `--nsg ""` rely on Azure default outbound, which works on first boot but disappears after the first deallocate/start cycle. The `Hibernate-ArcDemo.ps1` script intentionally **deletes** the NAT Gateway when hibernating to save cost, and **`Activate-ArcDemo.ps1` recreates it** before starting the VMs. Do not "optimise" this away.

2. **The Linux Arc GC extension stack is broken on Ubuntu 22.04 + `MSFT_ARC_TEST=true`.** `gcad` and `extd` enter a restart loop and `AzureMonitorLinuxAgent` installed via Arc extension never finishes provisioning. **The workaround: install AMA, CT, and DepAgent on Linux via the Azure VM extension path** (`az vm extension set`), not via the Arc extension path (`az connectedmachine extension create`). Windows uses the Arc path; Linux does not.

3. **DCR associations must target the Arc HybridCompute resource ID, not the Azure VM resource ID,** *even when* you installed the agent via the Azure VM extension path. When the Linux AMA detects the Arc agent, it pulls config from Arc IMDS, which only sees DCR associations attached to the Arc resource. If you don't see Heartbeat in Log Analytics, this is why.

4. **`Standard_B2s` / `Standard_B2ms` are frequently capacity-restricted** in `australiaeast` and `australiasoutheast` in MCAPS subscriptions. The default SKU in this repo is `Standard_B2as_v2` (2 vCPU / 8 GiB AMD burstable). Probe with `az vm create ... --validate` before assuming a SKU is available.

5. **Azure CLI on Windows mangles URLs containing `?` and `()`.** PowerShell shells out to `cmd.exe`, which treats `?` as a wildcard and `()` as grouping. This affects any `az rest --url` call where the URL contains `?api-version=...` AND a parenthesised resource name (the OMS Solutions API does both, e.g. `solutions/VMInsights(law-name)?api-version=...`). **The repo uses native `Invoke-RestMethod` with an `az account get-access-token` bearer token in these cases.** Do not switch them back to `az rest`.

6. **The Azure CLI's `az policy assignment create` and `az monitor data-collection rule create --rule-file` are buggy** with the payloads the demo needs. The repo uses `Invoke-RestMethod` (PUT) directly for those resources. Do not switch them to `az`.

## Code style & conventions

- **PowerShell scripts** use approved verbs (`Verb-Noun.ps1`), parameter validation attributes, `CmdletBinding(SupportsShouldProcess)`, write to `$VerbosePreference`-aware streams, and emit structured objects, never `Write-Host` (except for top-level progress banners). PSScriptAnalyzer is enforced via `.github/workflows/lint.yml`.
- **Bicep modules** in `bicep/modules/`, top-level template in `bicep/main.bicep`. Always `az bicep build` before commit.
- **Don't introduce new top-level dependencies.** This repo intentionally uses only `az`, `pwsh 7+`, and `Invoke-RestMethod` (built into PS). Adding Terraform / Pulumi / `Az` PowerShell module / etc. is out of scope.
- **Idempotency is mandatory.** Re-running any script must be a no-op against an already-correct state. Test with `Deploy-ArcDemo.ps1` twice in a row.

## Happy-path command sequence

```powershell
# 1. Clone & cd
git clone https://github.com/corey-skapin/arc-demo C:\src\arc-demo
cd C:\src\arc-demo

# 2. Sign in to the target tenant
az login --tenant <TENANT_ID>
az account set --subscription <SUBSCRIPTION_ID>

# 3. Verify prereqs
.\scripts\Test-Prerequisites.ps1 -SubscriptionId <SUB> -TenantId <TENANT>

# 4. Deploy
.\scripts\Deploy-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -AdminEmail you@contoso.com

# 5. After the demo, hibernate
.\scripts\Hibernate-ArcDemo.ps1

# 6. Before the next demo, activate
.\scripts\Activate-ArcDemo.ps1

# 7. When done permanently
.\scripts\Remove-ArcDemo.ps1
```

## Things this repo intentionally does NOT do

If asked to add any of the following, push back first and confirm:

- **Production-grade hardening** (managed identities everywhere, private endpoints for LAW, Just-in-Time VM access, KV firewall, NSG inbound rules). This is a *demo lab*, not a production reference.
- **VM image hardening / CIS benchmarks.** The whole point of the demo is to show *un-hardened* machines with vulnerabilities for Defender to flag.
- **Multi-region / HA.** Single region, single LAW.
- **Real ServiceNow / PagerDuty integration.** The Action Group is configured for email + has a documented one-liner to add a webhook later.
- **Bicep-only deployment.** Some steps (Arc onboarding via Run Command, agent restart, post-deploy validation) are imperative by nature. The Bicep template handles the static infra; the PowerShell wrapper drives the imperative bits. This split is deliberate.

## Why we Arc-enable Azure VMs (for the AI's understanding)

In reality, you'd never Arc-enable an Azure VM — Arc is for non-Azure compute. But for a demo, we need machines that *act* like on-prem servers without the cost of running an on-prem hypervisor. Microsoft supports this via the `MSFT_ARC_TEST=true` environment variable on the Connected Machine Agent installer — it bypasses the "you're already on Azure" guard. See [the Microsoft Learn warning](https://aka.ms/azcmagent-testwarning) for the official guidance. This is a fully supported scenario for testing and demo purposes only — don't use it for production workloads.

## Validation & testing

Always run the test cycle locally before pushing:

```powershell
# Lint
Invoke-ScriptAnalyzer -Path .\scripts\ -Recurse -Severity Warning

# Bicep build
az bicep build --file .\bicep\main.bicep --stdout > $null

# Dry-run deploy (validates Bicep + checks RBAC, no resources created)
.\scripts\Deploy-ArcDemo.ps1 -WhatIf -SubscriptionId <SUB> -TenantId <TENANT> -AdminEmail test@example.com

# Full smoke test cycle (~45 min total). Run manually with prefix "arctest":
.\scripts\Deploy-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -AdminEmail you@contoso.com -NamePrefix arctest
.\scripts\Hibernate-ArcDemo.ps1 -NamePrefix arctest
.\scripts\Activate-ArcDemo.ps1 -NamePrefix arctest
.\scripts\Remove-ArcDemo.ps1 -NamePrefix arctest
```

## When something breaks

The first place to look is [`docs/troubleshooting.md`](docs/troubleshooting.md) — every failure mode I've personally hit is documented there with a verified fix.

If the user reports an issue that isn't in `troubleshooting.md`, **add it** as part of the same change.
