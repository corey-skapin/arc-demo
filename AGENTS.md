# AGENTS.md

This file is for AI tools. You are working for the person who cloned this repo and asked for a task: build the lab, wake it, park it, remove it, run an incident, or change the repo. Their request is the go-ahead for that task, so don't ask them to approve each step of it again.

## What this repo does

A single-region, deliberately un-hardened Azure Arc and Azure Monitor demo with a 25-28 minute story. Azure VMs (five Windows, three Linux) are Arc-enabled with `MSFT_ARC_TEST=true`, so they stand in for on-premises servers; that is a demo trick, not a production pattern. Bicep and `Deploy-ArcDemo.ps1` build the estate: Arc machines, a Log Analytics workspace, data collection rules, alerts, policy, Defender and workbooks. A Container App, AKS, an Azure-native VM, real SQL on a host and a nested Windows/SQL/Arc guest are optional. The SRE agent half is the companion repo (`../sre-agent`).

Don't add production hardening, multi-region or HA, CIS images, real ITSM integrations or a Bicep-only redesign unless the user asks. SQL stays optional: the base simulation keeps Arc SQL/BPA off, and simulated events are never proof of a SQL engine ([docs/sql-arc-spike.md](docs/sql-arc-spike.md)).

## Commands

Run from the repo root. Every script takes `-SubscriptionId` and `-TenantId`; the private skin (`-SkinPath`) holds the rest. [docs/README.md](docs/README.md) is the docs index, the [runbook](docs/runbook.md) is the procedure, [lifecycle](docs/lifecycle.md) is the park, wake and remove contract, and [troubleshooting](docs/troubleshooting.md) covers failures.

```powershell
$target = @{ SubscriptionId = '<SUB>'; TenantId = '<TENANT>'; SkinPath = '<PRIVATE>\arc-skin.json' }
$build  = @{ SubscriptionId = '<SUB>'; TenantId = '<TENANT>'; BuildConfigPath = '<PRIVATE>\build.json' }

.\scripts\Test-Prerequisites.ps1 @target                          # read-only preflight
.\scripts\Invoke-ArcDemoBuild.ps1 @build                          # build everything in order: plans by default, -Execute runs it
.\scripts\Deploy-ArcDemo.ps1 @target -AdminEmail <EMAIL>         # base estate only; -WhatIf previews it
.\scripts\Test-ArcDemoReadiness.ps1 @target -DesiredState Active -OutputFormat Json   # or Hibernated, Removed; exit 0 pass, 1 fail, 2 pending
.\scripts\New-PresenterRunsheet.ps1                               # offline: .local\demo-context.json -> .local\presenter-runsheet.md
.\scripts\Hibernate-ArcDemo.ps1 @target                           # park
.\scripts\Activate-ArcDemo.ps1 @target                            # wake
.\scripts\Remove-ArcDemo.ps1 @target                              # remove
.\scripts\Invoke-SqlEngineOnArc.ps1 @target -MachineName win-sql-01 -Action Incident   # SQL lock-timeout incident
```

- The build wrapper's `-Approve…` and `-Accept…` switches mean "start billable resources" or "accept this licence". Pass the ones its plan lists when the request covers them.
- An incident needs a healthy SQL host (`-Action Status`) and the alert from `Set-SqlIncidentAlert.ps1`; the SRE agent half runs from the companion repo. To run one live incident once both layers are Active, follow "Run one incident after setup (optional)" in `../sre-agent/docs/ai-deploy-handbook.md#run-one-incident-after-setup-optional` (if the companion repo is present). In Review mode the SRE agent waits for a person to click Approve in the SRE portal. Nobody else can, and you must not try: when it is waiting, tell the user "The SRE agent is waiting for you to click Approve in the SRE portal."
- Park the SRE companion before Arc. Wake Arc and verify it is Ready before the companion.

## Private config

Targets, skins, credentials, build state and dated evidence live in a private folder outside git ([docs/private-config.md](docs/private-config.md)). Generated context and the runsheet live in the gitignored `.local/`. `config/demo-media.json` is the one tracked file that pins downloads (public Microsoft URLs, sizes, SHA-256).

## Safety rules

- Confirm the tenant and subscription with the user once at the start of a session, then pass both to every script. Don't silently switch Azure accounts or the CLI default subscription.
- Preview removals and other destructive steps with `-WhatIf` and show the user the preview before you run them: Remove, `-ForceDeleteWorkspace`, `-PruneDeploymentHistory`, `-DisableDefender`, anything that deletes data or converts a disk. If the preview lists something the user didn't ask for, stop and say so.
- Don't delete or change what the scripts don't own or deliberately keep: credentials (VM admin password, onboarding app, existing secrets), fault flags, disks and data, identities and RBAC, logs, the Defender plan, policy assignments, stuck extensions. Don't rotate, reset or "repair" them to turn a check green; read the row and say what it means.
- Keep secrets, tenant and subscription IDs, email addresses, customer names and private paths out of git, commit messages and PR text. Use the placeholders and fictional defaults the repo ships with.
- When a read is denied or a script fails, report the real error. Don't go around a denial with another tool, and don't change VM size or region on your own when Azure refuses an allocation.

## Changing the repo

- Static infrastructure goes in Bicep (`bicep/main.bicep`, modules in `bicep/modules/`); onboarding and validation go in PowerShell. Add no framework or dependency beyond `az`, PowerShell and built-in REST.
- Keep scripts idempotent: a rerun keeps credentials, fault flags, disks and data. Use approved verbs, `ShouldProcess`/`-WhatIf` and structured output.
- Before you finish, run what CI runs: `Invoke-ScriptAnalyzer -Path .\scripts\ -Recurse -Settings .\PSScriptAnalyzerSettings.psd1`, `Invoke-Pester -Path .\tests`, `az bicep build --file .\bicep\main.bicep --stdout` and markdownlint. The tests mock Azure; they never need a subscription.
- Change the docs with the code, add a new symptom to [docs/troubleshooting.md](docs/troubleshooting.md) with its cause and fix, keep [docs/module-map.md](docs/module-map.md) current, and update `config/expected-inventory.json` when a build creates a new named object.
- Scan what you changed for secrets and private identifiers before you push.

## Preserve platform workarounds

- Linux AMA and ChangeTracking go through the Azure VM extension path in this lab; Windows uses Arc extensions. DCR associations stay on the Arc resource ID for simulated Arc hosts (the VM ID for native hosts). The Linux Dependency Agent and VM Insights map stay off.
- Keep native `Invoke-RestMethod` (through `Invoke-AzRest`) for OMS solution URLs containing `?` or parentheses and for policy assignment and DCR PUTs; the CLI paths are buggy.
- Fresh OS disks are Standard SSD. An existing HDD estate keeps `Standard_LRS` through the retained-tier guard; Deploy never converts a disk.
- Wake restores a NAT gateway and public IP before it starts compute (there is no default outbound). Park removes them last: stop compute, detach the subnet, delete the NAT gateway, delete the public IP.
- Deploy leaves an enabled Defender for Servers plan (tier, subPlan, extensions) alone: a PUT without `extensions` strips them.
- Don't delete stuck Arc extensions, restart agents or change antivirus mode from a health inspection.
- Managed Run Command allows 25 saved commands per VM; the helper removes only its own completed ones.
