# AGENTS.md

This file is for AI tools. You are working for the person who cloned this repo and asked for a task: build the lab, wake it, park it, remove it, run an incident, or change the repo. Their request is the go-ahead for that task, so don't ask them to approve each step of it again. The one exception is the short list of questions and acceptances under "Before you start", which you put to them once, up front.

## What this repo does

A single-region, deliberately un-hardened Azure Arc and Azure Monitor demo with a 25-28 minute story. Azure VMs (five Windows, three Linux) are Arc-enabled with `MSFT_ARC_TEST=true`, so they stand in for on-premises servers; that is a demo trick, not a production pattern. Bicep and `Deploy-ArcDemo.ps1` build the estate: Arc machines, a Log Analytics workspace, data collection rules, alerts, policy, Defender and workbooks. A Container App, AKS, an Azure-native VM, real SQL on a host and a nested Windows/SQL/Arc guest are optional. The SRE agent half is the companion repo [sre-agent-demo](https://github.com/corey-skapin/sre-agent-demo) (clone it anywhere and point `sre.repoPath` in `build.json` at the clone).

Don't add production hardening, multi-region or HA, CIS images, real ITSM integrations or a Bicep-only redesign unless the user asks. SQL stays optional: the base simulation keeps Arc SQL/BPA off, and simulated events are never proof of a SQL engine ([docs/sql-arc-spike.md](docs/sql-arc-spike.md)).

## Before you start

- Your first message asks the user, once and in one list, for the tenant ID, the subscription ID, the acceptances below and, when the SRE half is wanted, whether the subscription is registered for Azure SRE Agent. Ask for nothing else, except an e-mail address when the signed-in name isn't one (see Defaults). Every other choice has a default below: use it and list what you used in your final summary. The user's own choices (another region, another shutdown time, Arc only) win over the defaults.
- Acceptances, by name. Pass a switch only after the user says yes to it, and never accept licence terms for them. The whole demo needs four: start billable resources (`-ApproveCostStart`; give the plan's minutes plus roughly 20 for the Container Apps environment, which the plan doesn't count: about 2 hours 45 minutes in all for the whole demo, about 90 minutes for Arc only; point at [docs/cost.md](docs/cost.md), and say that Defender for Servers Plan 2 is enabled subscription-wide, isn't in that estimate and stays after Remove unless `-DisableDefender` is passed); the SQL Server Developer licence terms (`-AcceptSqlDeveloperTerms`); the paid SRE agent (`-ApproveSreCreation`; 4 AAU per hour from creation until it is parked or removed); and the one subscription-scope role assignment that lets the agent read Azure Monitor alerts (`-ApproveSubscriptionGrant`). The Windows Server evaluation terms (`-AcceptWindowsEvaluationTerms`) matter only if the nested guest is built. If the plan's "To run it" line later lists a switch the user hasn't accepted, ask for that one. If they decline one, don't build what needs it: without the SQL terms delete the `realSql` section; without the SRE agent or the grant build Arc only or stop before P8 (next bullet); and say what the demo then lacks.
- SRE registration. Only the portal shows it: at [sre.azure.com](https://sre.azure.com) choose Create agent, pick the subscription and open the Region dropdown. An empty dropdown means it isn't registered, and the [supported-regions page](https://learn.microsoft.com/azure/sre-agent/supported-regions) links the registration request (a GitHub issue that asks for the subscription ID). If it isn't, build the Arc half with `-To P7`, tell the user how to ask for registration, and continue later with `-From P8` (P8 to P11), passing the SRE acceptances then. If the 19:00 shutdown has stopped the VMs by then, run `Activate-ArcDemo.ps1 @target` first.
- Defaults. E-mail for alerts and the budget: the signed-in account's name (`az account show --query user.name -o tsv`) when it contains `@` and not `#EXT#`, otherwise ask once; Deploy rejects the shipped `operator@example.com`. Region: `australiaeast`, which is on the SRE Agent supported-regions list. Scope: the whole demo ("Build the whole demo" below); Arc only (see Commands) only if the user asks. Nested guest: off; if the user asks for it, enable it in the skin as [docs/nested-sql-demo.md](docs/nested-sql-demo.md) says and save `nested-guest-credential.clixml` yourself with the generated-password recipe in [docs/private-config.md](docs/private-config.md#saving-the-nested-guest-credential), so the user types nothing. Private folder: `$HOME\arc-demo-private`.
- Shutdown: 19:00 in this PC's time zone. Set `operations.autoShutdownTimezone` in the private skin to `(Get-TimeZone).Id` and keep `autoShutdownTime` at `1900`; the shipped `Cen. Australia Standard Time` is the author's, and 19:00 there is morning in Europe, which would stop the VMs in the middle of a working day. If P0 warns that the build would cross the shutdown time, set `autoShutdownTime` in `build.json` (HHmm) to a time after the build ends and say so: Deploy sets the schedule on every run, so changing it later takes another Deploy.
- Tools and rights: PowerShell 7.4+ (run every script with `pwsh`, not Windows PowerShell 5.1, where a script stops with a version message), Azure CLI 2.60+ with Bicep, Git, Owner (or Contributor plus User Access Administrator) on the subscription, and the right to create an Entra app registration and secret for `sp-<prefix>-onboard` (without it Deploy fails in phase 4, after the VMs exist). Preflight installs and registers nothing: run the commands it prints for missing CLI extensions, resource providers and features, then rerun it. Real builds were run only from a Windows PC (CI also runs the mocked tests on Linux), so other systems are untested (the saved passwords are DPAPI-protected, which is Windows-only; elsewhere they are saved unencrypted, with a warning).
- Sign-in: if `az` isn't signed in to the user's tenant (`az account show --subscription <SUB>` fails), ask the user to run `az login --tenant <TENANT>` and wait. Don't run it yourself.

## Build the whole demo

1. Set up the private folder with the block in [docs/private-config.md](docs/private-config.md#set-up-the-whole-demo). It writes the Arc skin (the e-mail, the time zone and `workloads.deployContainerApps` set to `true`: the SRE half needs the Container App `ca-<prefix>-fault`, or P9 stops after hours of build, so set it before P2; it adds roughly 17-23 minutes, and on an existing estate you add it with the second pass in [docs/lifecycle.md](docs/lifecycle.md#adding-an-optional-workload-to-a-running-estate)). It clones the companion repo, [sre-agent-demo](https://github.com/corey-skapin/sre-agent-demo), writes `<PRIVATE>\sre-skin.json` from the clone's `config\demo-skin.json` with the Arc skin's `azure.namePrefix` and `azure.location` (they ship equal, so the default scenarios need nothing else), and writes `build.json` with `sre.repoPath` set to the clone.
2. Run `Test-Prerequisites.ps1` and fix what it prints. Then run the plan (`Invoke-ArcDemoBuild.ps1 @build`) and read it: the minutes, the switches under "To run it", any blocker and P0's notes.
3. Run `-Execute` as a background or detached process: the whole demo takes about 2 hours 45 minutes, far longer than a shell call lasts. Start it from the repo root (the script path is relative, so the working directory matters) with its output going to the private folder, passing only the switches the user accepted:

   ```powershell
   $run = '-NoProfile -NonInteractive -File .\scripts\Invoke-ArcDemoBuild.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -BuildConfigPath "<PRIVATE>\build.json" -Execute -Confirm:$false -ApproveCostStart -AcceptSqlDeveloperTerms -ApproveSreCreation -ApproveSubscriptionGrant'
   Start-Process pwsh -ArgumentList $run -WorkingDirectory <REPO_ROOT> -RedirectStandardOutput '<PRIVATE>\build.log' -RedirectStandardError '<PRIVATE>\build.err' -PassThru
   ```

   Then poll `<PRIVATE>\build.log` and `<PRIVATE>\build-state.json` (each step's `status` is `running`, `done`, `failed` or `blocked`, with a `message`) rather than waiting on one call. `pwsh -File` passes a list such as `-Only P6.2, P6.3` as one string, which the wrapper rejects: for `-Only`, use `-Command` instead of `-File`.
4. If your shell times out or the session is interrupted, first check that no earlier run is still alive (`Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'Invoke-ArcDemoBuild' }`): two runs at once would work on the same steps. Then run the same command again; it resumes at the first step not recorded as done. A rerun refuses to start while Deploy's own deployment is still Running (wait, then rerun), and a failed or interrupted P4 or P9 step stays blocked until you have inspected it and pass `-Force` ([runbook](docs/runbook.md#build-everything-in-order-optional-wrapper)).
5. When it finishes, tell the user which default you used for each choice, what P7, P9.3 and P11 reported, and where the runsheet is (`.local\presenter-runsheet.md`).

## Commands

Run from the repo root. Every script takes `-SubscriptionId` and `-TenantId`; the private skin (`-SkinPath`) holds the rest. [docs/README.md](docs/README.md) is the docs index, the [runbook](docs/runbook.md) is the procedure, [lifecycle](docs/lifecycle.md) is the park, wake and remove contract, and [troubleshooting](docs/troubleshooting.md) covers failures.

```powershell
$target = @{ SubscriptionId = '<SUB>'; TenantId = '<TENANT>'; SkinPath = '<PRIVATE>\arc-skin.json' }
$build  = @{ SubscriptionId = '<SUB>'; TenantId = '<TENANT>'; BuildConfigPath = '<PRIVATE>\build.json' }

.\scripts\Test-Prerequisites.ps1 @target                          # read-only preflight
.\scripts\Invoke-ArcDemoBuild.ps1 @build                          # build everything in order: plans by default
.\scripts\Invoke-ArcDemoBuild.ps1 @build -Execute -Confirm:$false <the switches the user accepted>   # run the plan
.\scripts\Deploy-ArcDemo.ps1 @target -AdminEmail <EMAIL> -AdminPasswordPath <PRIVATE>\vm-admin-credential.clixml   # base estate only; -WhatIf previews it
.\scripts\Test-ArcDemoReadiness.ps1 @target -DesiredState Active -OutputFormat Json   # or Hibernated, Removed; exit 0 pass, 1 fail, 2 pending
.\scripts\New-PresenterRunsheet.ps1                               # offline: .local\demo-context.json -> .local\presenter-runsheet.md
.\scripts\Hibernate-ArcDemo.ps1 @target                           # park
.\scripts\Activate-ArcDemo.ps1 @target                            # wake
.\scripts\Remove-ArcDemo.ps1 @target -WhatIf                      # preview the removal and show it to the user
.\scripts\Remove-ArcDemo.ps1 @target -Confirm:$false              # remove, once that preview has been shown
.\scripts\Invoke-SqlEngineOnArc.ps1 @target -MachineName win-sql-01 -Action Incident   # SQL lock-timeout incident
```

- The build wrapper's `-Approve…` and `-Accept…` switches are the acceptances above: pass only the ones the user said yes to. `-Execute` and `Remove-ArcDemo.ps1` prompt for confirmation, which a tool's non-interactive shell can't answer: add `-Confirm:$false` to both (to Remove only after you have shown the `-WhatIf` preview).
- Prefer the wrapper to running Deploy alone: only it passes `-AdminPasswordPath`, which saves the generated VM admin password in the private folder before anything is created. Deploy writes the password to the Key Vault only after the Bicep deployment succeeds, so a first Deploy without that file that fails part way (a capacity, quota or policy error, for example) has kept it only in memory and can't be resumed: the rerun stops with "Retained vault without current compute" or "Existing VMs found but no saved admin credential". If you run Deploy alone, pass `-AdminPasswordPath <PRIVATE>\vm-admin-credential.clixml` on the first run and every run after it (a tenant policy that makes the Key Vault private-only needs it for reruns too).
- `build.json` is `config\build-plan.example.json`, the full build (real SQL, the SRE half and a LOB host), with `sre.repoPath` set to the clone. A hand-copied example still has the placeholder path, which blocks P8 and P9, so `-Execute` refuses to start. For an Arc-only build (about 90 minutes, only `-ApproveCostStart`) delete the `realSql` and `sre` sections, clear `presenter.lobMachineName` and leave `workloads.deployContainerApps` false.
- If the SRE parent exists but the grant was forgotten, the [runbook](docs/runbook.md#build-everything-in-order-optional-wrapper) has the fix.
- The SQL incident needs a healthy SQL host (`-Action Status`) and the alert from `Set-SqlIncidentAlert.ps1`; the Container App incident needs no SQL. The SRE agent half runs from the companion repo: to run one live incident once both layers are Active, follow its handbook section "Run one incident after setup (optional)". In Review mode the SRE agent waits for a person to click Approve in the SRE portal. Nobody else can, and you must not try: when it is waiting, tell the user "The SRE agent is waiting for you to click Approve in the SRE portal."
- Park the SRE companion before Arc. Wake Arc and verify it is Ready before the companion.

## Private config

Targets, skins, credentials, build state and dated evidence live in a private folder outside git (by default `$HOME\arc-demo-private`; [docs/private-config.md](docs/private-config.md)). Generated context and the runsheet live in the gitignored `.local/`. `config/demo-media.json` is the one tracked file that pins downloads (public Microsoft URLs, sizes, SHA-256).

## Safety rules

- Use the tenant and subscription the user gave you in the first ask, and pass both to every script. Don't silently switch Azure accounts or the CLI default subscription.
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
