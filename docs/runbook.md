# Azure Arc demo build and operations runbook

This page is how you set up, validate, present, park and wake, and remove the lab. It
is not the presentation script: you present from the runsheet generated at
`.local/presenter-runsheet.md` ([the docs index](README.md) lists everything else).
Work down the page: [choose the target](#1-choose-the-target-and-skin),
[preflight](#2-read-only-preflight-and-preview), [deploy](#3-deploy) or
[build everything in order](#build-everything-in-order-optional-wrapper),
[validate](#4-validate-then-rehearse), [prepare your runsheet](#prepare-the-local-presenter-guide)
and the [optional workbooks](#optional-capacity-and-optimisation-workbooks),
[park and wake](#5-park-and-wake), then [remove](#6-remove-permanently). If you change
the repo, [validate it locally](#7-local-development-validation).

The maintained deployment path is `scripts\Deploy-ArcDemo.ps1` plus Bicep. Do not
replay old ad-hoc portal/CLI builds against a running demo. Start with
[AGENTS.md](../AGENTS.md) and the [lifecycle safety/contract](lifecycle.md); the
[runsheet template](runsheet.md) matters only when you generate your runsheet.

## 1. Choose the target and skin

Use a demo subscription where you have effective subscription Owner or
Contributor plus User Access Administrator, and permission to create an Entra app
registration and secret for the Arc onboarding identity (`sp-<prefix>-onboard`) if
needed, or to add and remove a credential on the existing one (application owner or
administrator). Deploy first uses that permission at phase 4, after the VMs exist, so
check it before you start. PowerShell 7.4+ (run the scripts with `pwsh`, not Windows PowerShell
5.1), Azure CLI 2.60+ and
Bicep are required, and Git to clone the SRE companion repo. No Az PowerShell module or
production framework is required. An Arc-only build needs no SRE Agent; the SRE half needs a
subscription registered for it ([how to check](#sre-agent-registration)).

Sign in yourself: `az login --tenant <TENANT>` opens a browser, so a tool cannot do it
for you. If your AI tool is running these steps, it asks you to sign in and waits.

```powershell
az login --tenant <TENANT>
az account show --subscription <SUB> --query "{id:id,tenantId:tenantId,user:user.name}" -o table
$target = @{ SubscriptionId = '<SUB>'; TenantId = '<TENANT>'; SkinPath = '<PRIVATE_SKIN_PATH>' }
```

Confirm those values; do not rely on default CLI context. Copy a bundled skin
outside git for a new lab; edit that private copy's email, region, shutdown time and
time zone, labels, prefix and workload toggles (the shipped region, `australiaeast`, and
shutdown, 19:00 Cen. Australia Standard Time, are the author's). The
[setup block](private-config.md#set-up-the-whole-demo) makes that copy for a whole-demo
build (your signed-in address as the e-mail, this PC's time zone for the 19:00 shutdown) and
sets up the SRE half too. Preserve an existing
lab's retained inputs instead.
IDs and secrets stay out of source.
`config\dummy-customer.demo-skin.json` illustrates portability. An explicit missing
skin, malformed boolean, invalid prefix or fleet is an error, never a fallback.
Relative fleet paths resolve against the repo root.

## 2. Read-only preflight and preview

```powershell
.\scripts\Test-Prerequisites.ps1 @target
.\scripts\Deploy-ArcDemo.ps1 @target -AdminEmail <EMAIL> -WhatIf
```

Preflight does not register providers or subscription features, install CLI extensions or change context.
It reports every unregistered provider, every unregistered subscription feature
(`Microsoft.Compute/UseStandardSecurityType`, when the skin declares the nested SQL parent) and every
missing CLI extension (`connectedmachine`, plus `containerapp` for Container Apps) in one error with
the exact fix, for example `az extension add --name containerapp --yes` (that extension is
preview-only today and takes about 2 minutes, so installing it means your build uses a preview
extension); resolve missing providers and features yourself, using the exact ones reported
by preflight for the skin's workload toggles (`Test-Prerequisites.ps1`, Deploy and
the build wrapper's P0 check the same set). Supplying
`-DeployerPrincipalId <OBJECT_ID>` (your own; read it from your ARM token when Graph is blocked, see
[the CAE entry](troubleshooting.md#microsoft-graph-calls-fail-with-a-continuous-access-evaluation-challenge))
bypasses only Graph user discovery, not RBAC.
SKU restriction and regional/family vCPU quota are checked by Deploy's own first step, not by this
preflight or the wrapper's P0: about 4 minutes, announced on the console, before anything is created.
These checks do not guarantee capacity. If Azure still
refuses allocation, Deploy prints the options and never switches VM size or
region on its own; re-running the same command resumes.
Review the [cost assumptions](cost.md) before you deploy.

## 3. Deploy

```powershell
.\scripts\Deploy-ArcDemo.ps1 @target -AdminEmail <EMAIL> -AdminPasswordPath <PRIVATE>\vm-admin-credential.clixml
```

`-AdminPasswordPath` saves the generated VM admin password before any Azure write, and the
build wrapper always passes it. Deploy writes the password to the Key Vault only after the
Bicep deployment succeeds, so a first Deploy without the file that fails part way (a capacity,
quota or policy error, for example) has kept the password only in memory and can't be resumed.
The rerun stops with `Retained vault without current compute` or
`Existing VMs found but no saved admin credential`. When you run Deploy alone, pass
`-AdminPasswordPath` on the first run and on every run after it; the same file is how reruns
get the password when a tenant policy makes the vault private-only
([details](#existing-estates-and-partial-failures)).

Default: 5 Windows Server hosts across 2016/2019/2022 and 3 Ubuntu 22.04 hosts,
Arc-enabled with `MSFT_ARC_TEST=true` for this demo-only simulation. SQL-capable
hosts do not imply SQL Server is installed. Optional flags are independent:
`-DeployAzureVMs $true`, `-DeployContainerApps $true`, `-DeployAks $true`. On an existing
estate or in an Arc-only build, add a slow optional workload (the Container Apps environment
alone takes 17-23 minutes and can fail on its own) as a second pass once the base Deploy has
Succeeded, so a failure there cannot strand the base:
[how](lifecycle.md#adding-an-optional-workload-to-a-running-estate). The whole-demo build is the
exception: the SRE half needs the Container App, so the
[setup block](private-config.md#set-up-the-whole-demo) sets the flag before P2 and the first
Deploy creates it. If P2 stops on the environment (`ManagedEnvironmentProvisioningError`, a
transient platform error), rerun the same wrapper command: it resumes P2 and reuses the saved
admin password; don't Remove.
For custom tiers, use `-OnPremFleetPath <fleet.json>`; see
[legacy fleet support](legacy-os-fleet.md). Represented legacy hosts are not
reported as deployed.

Real SQL setup is a separate step using
[the isolated Developer workload helper](sql-engine-workload.md).
Deployment has no SQL installation switch; use the separate SQL build/workload helpers.

Bicep provisions static resources in `rg-<prefix>` (Arc/Monitor) and
`rg-<prefix>-infra` (backing/optional compute). Deploy submits the deployment without
blocking (`--no-wait`) and polls it every 30 seconds, printing which modules are still
running whenever that changes (a Container Apps environment takes 17 to 23 minutes, a
VM behind a vendor extension update can take much longer), so a lost client connection no
longer ends the build and the console is never silent for tens of minutes. Polling gives up
after 4 hours without stopping the deployment, and a rerun refuses to start while one is still
Running. The wrapper handles DCR table
readiness/retries, NAT, Arc onboarding, supported extensions/DCRAs and workbooks.
Linux AMA and CT use VM extensions but Arc DCRAs. Windows VM Insights map is
supported by the lab; Linux map remains disabled. Runtime errors stop deployment
rather than printing a false success.

### Existing estates and partial failures

Do not deploy over an in-use estate just to test a code change. First collect
read-only readiness and work out the exact reconciliation you need.
Preserve subscription deployment history while the estate exists: it is the
lifecycle manifest. After `Remove-ArcDemo` the infra group is gone, so Deploy ignores
the stale manifest and builds a fresh Key Vault; `Remove-ArcDemo.ps1
-PruneDeploymentHistory` (opt-in) deletes this demo's own old records.
Incremental optional-only deployments do not delete earlier Arc hosts.

`Deploy-ArcDemo.ps1` does not regenerate VM credentials on a routine redeploy. Reuse the existing
Key Vault secret; old labs without it, and labs whose vault a tenant policy made private-only,
must supply their **current** `-AdminPassword` as a SecureString or the file an earlier run saved
with `-AdminPasswordPath` (a fresh build saves one before any Azure write, so a build that fails part way
resumes with the same command; the wrapper always passes it, see
[the private folder](private-config.md)). New Arc onboarding needs no supplied secret:
Deploy ensures an existing SP's Arc-group role and uses a one-day credential it
removes afterwards (see [credentials](lifecycle.md#credentials-and-partial-deployments));
no routine SP credential reset. If the VM credentials are missing, supply the
current ones as above; never silently rotate them. The VM password is an estate-deployment
input, not a nested-build prerequisite: the
[nested build](nested-sql-demo.md) needs no vault and uses the same one-day
credential flow.

Match the effective disk tier too: fresh deployments default to SSD, but an
existing HDD lab requires `-OsDiskStorageAccountType Standard_LRS` or that value
in its private skin. The wrapper refuses mismatches even during preview; it
does not convert disks. Keep the HDD tier your lab has and plan any
migration separately before HDD OS support retirement. See [cost.md](cost.md).
A governance automation can also convert a parked estate's disks to HDD on its
own, so a Deploy that refuses the tier after a Hibernate is not a script fault:
declare the tier the disks have now (and
`nestedSqlGuest.parentDataDiskStorageAccountType` for the nested parent), see
[the OS disk tier changed by itself](troubleshooting.md#the-os-disk-tier-changed-by-itself).

## Build everything in order (optional wrapper)

`scripts\Invoke-ArcDemoBuild.ps1` runs the maintained scripts in one fixed order
(P0-P11) for a from-zero build of the base estate and the optional parts. It adds
no logic of its own: every step is an existing script, so the other sections of this
page still describe what each step does. It is **plan only by default**. `-Execute` runs the
steps not yet recorded as done in the private `build-state.json`, so a stopped
build resumes where it stopped. Keep the config, state and evidence in the
[private build folder](private-config.md).

```powershell
$build = @{ SubscriptionId = '<SUB>'; TenantId = '<TENANT>'; BuildConfigPath = '<PRIVATE>\build.json' }
.\scripts\Invoke-ArcDemoBuild.ps1 @build        # plan: order, status, switches needed, blockers, time
.\scripts\Invoke-ArcDemoBuild.ps1 @build -Execute -From P2 -To P4 `
    -ApproveCostStart -AcceptWindowsEvaluationTerms -AcceptSqlDeveloperTerms
```

| Step | What runs | Needs |
| --- | --- | --- |
| P0, P1 | Read-only preflight (tools, access, providers, repo state, soft-deleted workspace name, and the build window: the typical minutes plus a 50% allowance against the VM auto-shutdown, which Deploy sets again on every run, so set `autoShutdownTime` before the build if it would cross) and onboarding-identity check | |
| P2 | `Deploy-ArcDemo.ps1` with the private skin. It saves the generated VM admin password to `vm-admin-credential.clixml` in the private folder before any Azure write, so a failed P2 reruns with the same password even when a tenant policy made the vault unreadable. Its last phase runs read-only Active readiness (up to 20 minutes for Heartbeats) **without** the nested guest's `nested/arc` row, because the guest is built later at P4; a failure names the rows that did not pass | `-ApproveCostStart` |
| P3 | `Prepare-NestedSqlParent.ps1`: the Hyper-V parent for the nested guest. Runs after Deploy with the lab Active (it refuses a parked lab) and writes the nested build input into the private folder. A reported `status` of `pending` or `fail` is not recorded as done, and it is safe to re-run | `-AcceptWindowsEvaluationTerms`, `-AcceptSqlDeveloperTerms` |
| P4 | `New-NestedSqlDemo.ps1`: takes the build input from P3, adds the parent and guest names, resolves the parent VM ID and onboarding application at run time, uses a one-day onboarding credential. The guest Administrator credential is resolved at the start of `-Execute`: `-GuestCredential`, else `nested-guest-credential.clixml` in the [private folder](private-config.md#saving-the-nested-guest-credential), else a prompt. A session that cannot prompt stops there, before anything starts. The wrapper only reads it and keeps it out of the evidence. Each guest step prints when it starts and, about once a minute, that it is still running | |
| P5 | Real SQL on the SQL host: `Stage-DemoMedia.ps1` stages the hash-pinned ISO from `config/demo-media.json` (or the config's `mediaManifestPath`), then `ProtectArcSql`, `Install`, `Status`. A fresh host often reports a routine pending file rename at `Install`: restart the SQL host once with a graceful `az vm restart` before P5, and see [the recipe](troubleshooting.md#sql-preparation-reports-a-pending-file-rename) | `-AcceptSqlDeveloperTerms` |
| P6 | `Set-SqlIncidentAlert.ps1` and `Set-OperationalWorkbook.ps1` (capacity, optimisation). The alert (P6.1) watches the SQL engine, so it needs P5.4's saved proof (`.local/sql-engine-status.json` with status `pass`): run on its own before P5 it is blocked rather than deploying an alert for an engine that does not exist, and inside one selection it runs after P5.4 and stops the same way if the proof is not `pass`. Each workbook records the Arc roster and tags at publish time, so a from-zero build publishes them once, here, after the guest exists, and a rerun after P2 or P4 finished later publishes them again (the plan says so). To refresh just the two workbooks later, for example after a tag repair or a new host, run `-Only P6.2, P6.3 -Force`: it leaves the SQL alert (P6.1) alone | |
| P7 | `Test-ArcDemoReadiness.ps1 -DesiredState Active`, re-checked for up to 20 minutes. This is the gate that includes the nested guest's `nested/arc` row (Deploy's own validation leaves it out) | |
| P8 | Companion repo ([sre-agent-demo](https://github.com/corey-skapin/sre-agent-demo), see below): LOB alert rule and LOB app | |
| P9 | Companion repo: `Deploy-SreAgent.ps1` preview, create, then readiness. The agent bills from creation; the create step passes the script's own `-ApproveParentCreation`. Preview and create are skipped when the parent already exists (see below) | `-ApproveSreCreation`, and `-ApproveSubscriptionGrant` on a first SRE build (see below) |
| P10 | Presenter context (`.local/demo-context.json`) and runsheet for this repo (the SRE guide only if its context exists). It stamps the context with the time of the last passing P7 readiness evidence, not the time P10 ran. It adds every optional chapter it can verify (the data collection rule, the four original workbooks found by their tag, the nested guest, its SQL instance and its parent) and prints and records the chapters it had to leave out because their resource was not found; build them, then run P10 again | |
| P11 | `Export-ArcDemoInventory.ps1`, then `Test-ArcDemoParity.ps1` | |

Pass `-ApproveCostStart` to confirm you want to start billable resources.
`-AcceptWindowsEvaluationTerms` and `-AcceptSqlDeveloperTerms` accept the Windows
evaluation and SQL Developer licence terms. `-ApproveSreCreation` creates the paid SRE
parent. `-ApproveSubscriptionGrant` adds the one subscription-scope Monitoring
Contributor grant that the SRE agent needs to read Azure Monitor alerts: pass it on a
first SRE build, unless the agent's identity already holds the grant, because the SRE
readiness row `azure-monitor-alert-access` fails without it. The plan lists the
switches your selection still needs, but not this one: it prints a hint line under the
command to remind you, so add the switch yourself.

- The plan shows each step as `ready`, `done`, `skipped` (with the reason) or
  `blocked`. Blocked means the script is not in the checkout yet, it does not
  accept an argument the wrapper passes, or an input file is missing.
- Nothing starts if any selected step is blocked, a switch it needs is missing,
  or the state records P2 as done while the infra group no longer exists (a
  teardown happened; delete the state file to start a new build). A launch that stops
  this way exits 1 and writes the reason to standard error, not to the state file: when
  you redirect the output, read the error file as well as the log (a blocked step prints
  the plan table first, a missing switch or file prints nothing to the log).
- If the plan prints "Read-only checks stopped: ..." above the table, it could not read
  Azure (usually the sign-in), so P0's notes and the shutdown-window warning are missing:
  fix the cause and run the plan again. `-Offline` skips those reads on purpose and prints
  only the order and the minutes. It is for looking at the order, never the go-ahead, and
  `-Execute` refuses it.
- Read-only steps (P0, P1, P5 `Status`, P7, P9 readiness, P11) run
  again on every `-Execute`. A failed or interrupted P4 or P9 deploy is not retried
  until you have inspected it and pass `-Force`; `-Force` also re-runs steps
  recorded as done. A step that could not even start (for example a lookup failed
  or the credential prompt was cancelled) is recorded as `blocked` and stays retryable.
- A build runs for hours, so a shell or session can stop partway. Run the same command
  again: it resumes at the first step not recorded as done. If P2 was interrupted while
  Deploy's own Azure deployment was still running, the rerun refuses to start and prints the
  `az deployment sub show` command to wait on: rerun once it says `Succeeded` or `Failed`.
  An interrupted or failed P4 or P9 needs the inspection and `-Force` above.
- The SRE half comes from the companion repo
  [sre-agent-demo](https://github.com/corey-skapin/sre-agent-demo). Clone it next to this
  repo or anywhere, set `sre.repoPath` in `build.json` to the clone, and copy the clone's
  `config\demo-skin.json` to `sre-skin.json` in your private folder (a relative `sre.skinPath`
  resolves against that folder). The skin's `azure.namePrefix` and `azure.location` must equal
  the Arc skin's. They ship equal, so nothing else changes for the default scenarios, and
  `labels.agentName` follows the prefix. The
  [setup block](private-config.md#set-up-the-whole-demo) does all of this.
- The subscription must also be registered for Azure SRE Agent and offer the skin's region.
  You [check that yourself](#sre-agent-registration) with one read-only command, and the user
  is asked only if the check can't confirm it.
- The SRE half also needs the Container App and the LOB app. The companion's
  `Deploy-SreAgent.ps1` requires the fault Container App `ca-<prefix>-fault` by default
  (`sre.requiredScenarios` defaults to T09, the Container App incident, and T11, the LOB app
  on Arc) and stops at P9 without it: after hours
  of build, though before it creates the paid parent. So set `workloads.deployContainerApps`
  to `true` in the private skin **before P2**; the Container Apps environment adds roughly
  17-23 minutes. P8 builds the LOB alert rule and app. On an existing estate, add the
  Container App as a second pass: set the flag in the same step as the Deploy that creates
  it, then run the same Deploy again
  ([how](lifecycle.md#adding-an-optional-workload-to-a-running-estate)).
- `Deploy-SreAgent.ps1` refuses an existing SRE parent, even with `-WhatIf`. So a
  read-only check of `rg-<prefix>-sre` (the agent name comes from the SRE skin)
  runs first: when the parent exists, P9 preview and create are **skipped**, not
  failed, and do not need `-ApproveSreCreation`; when the check cannot be read, they are `blocked`
  with the exact error. P9 therefore belongs after a confirmed removal; use
  `Initialize-SreConfiguration` for configuration-only changes to a running agent.
- If the parent exists but you forgot `-ApproveSubscriptionGrant`, grant it with the
  companion's `scripts\Grant-SreAzureMonitorAlertAccess.ps1` instead: run it with `-WhatIf`
  first, read the principal, role and scope it would assign, then run it again with
  `-GrantAzureMonitorAlertAccess`. It also takes `-PrincipalId` (the principal ID of the
  agent's managed identity, `<agent>-uami` in `rg-<prefix>-sre`) and the same `-SkinPath`.
  Then run the SRE readiness gate again with `-Only P9.3`.
- `-From` and `-To` take phase names; `-Only` takes phases or single steps (`-Only P6.2, P6.3`);
  `-WhatIf` is the same as the plan;
  pass `-Confirm:$false` for unattended runs. The plan's minutes are typical
  timings, not a promise: the whole demo (real SQL, the LOB app and the SRE half, without the
  nested guest) is about 146 minutes plus the 17-23 the Container Apps environment adds, so
  allow about 2 hours 45 minutes; an Arc-only build is about 90 minutes; the nested guest
  (P3 and P4) adds about 65. Billable resources start
  at P2; reprice with [cost.md](cost.md).
- The wrapper only builds. Teardown stays with `Hibernate-ArcDemo.ps1` and
  `Remove-ArcDemo.ps1` (and the companion's own scripts first); the opt-in
  `-ForceDeleteWorkspace` and `-PruneDeploymentHistory` switches for a same-prefix
  rebuild are described with Remove below and decided at teardown time.

### SRE Agent registration

The SRE half needs a subscription that is registered for Azure SRE Agent and offers the
skin's region (Australia East is on the
[supported-regions list](https://learn.microsoft.com/azure/sre-agent/supported-regions)).
Once you are signed in you can check this yourself, read-only. It is the allow-list check in
the [Azure SRE Agent troubleshooting FAQ](https://learn.microsoft.com/azure/sre-agent/faq-troubleshooting#deployment-issues):

```powershell
$ErrorActionPreference = 'Stop'
$location = '<azure.location from the Arc skin>'   # for example australiaeast
$regions = az provider show -n Microsoft.App --subscription <SUB> --query "resourceTypes[?resourceType=='agents'] | [0].locations" -o tsv
if ($LASTEXITCODE) { throw 'az failed: fix the sign-in; this is not an unregistered subscription' }
$listed = @($regions | Where-Object { $_ }).Count
$offered = @($regions | Where-Object { ($_ -replace '\s') -eq $location }).Count -gt 0
```

If the command itself fails, that is a sign-in or permission problem, not a registration answer:
fix it and run the check again. Otherwise it prints one region per line as a display name, so the
comparison ignores spaces and case (`Australia East` is `australiaeast`). Only the registered case
that lists the region has been verified. The other two outcomes are read from what the command
prints, which is why they say "probably" and "appears".

- **`$offered` is true:** the subscription is registered and offers the region. Carry on, and
  say in your final summary that you checked.
- **`$listed` is 0:** the subscription probably isn't registered. The portal is the authority,
  so ask the user once to confirm it: open [sre.azure.com](https://sre.azure.com), choose
  **Create agent**, pick the subscription and open the **Region** dropdown. An empty dropdown
  means it isn't registered, so the user asks for registration (see *Building before the agent
  can be created*, below); a dropdown that lists the region means it is, so carry on. This is
  the only time anyone is asked about registration.
- **`$listed` is above 0 but `$offered` is false:** the subscription appears registered but
  doesn't offer the skin's region, so there is nothing to confirm in the portal. This is the one
  registration ask: show the user the listed regions and let them pick one or keep theirs. For a
  listed region, set `$arc.azure.location` in the
  [setup block](private-config.md#set-up-the-whole-demo) before it writes the file (the canonical
  name is the display name without spaces, in lower case: `East US 2` is `eastus2`); the SRE skin
  follows, and Deploy's own capacity check still applies in that region. For their own region,
  build everything before the SRE steps and ask for the region (see *Building before the agent
  can be created*, below). Never switch the region on your own.
- **Building before the agent can be created** (registration or the region is still to come):
  build everything before the SRE steps now with `-Execute -To P7` (P0 to P7: about 116 minutes
  plus roughly 20 for the Container Apps environment, and it still needs `-ApproveCostStart` and
  `-AcceptSqlDeveloperTerms`) and tell the user how to ask. The supported-regions page links a
  [subscription registration request](https://github.com/microsoft/sre-agent/issues/new?labels=registration&title=Subscription+registration+request)
  and a
  [new region request](https://github.com/microsoft/sre-agent/issues/new?labels=region-request&title=New+region+request).
  Both are public GitHub issues (the registration one asks for the subscription ID, the region
  one for the region and the use case), so the user files it themselves; you never file one for
  them. Continue later with `-Execute -From P8`
  (P8 to P11) and the SRE switches. P10 and P11 (presenter guide and inventory) run in that later
  pass; `-Only P10, P11` runs them earlier. If the 19:00 shutdown has stopped the VMs by then, run
  `Activate-ArcDemo.ps1` first: P8 runs on a host and P9 readiness needs the lab Active. An
  Arc-only build (no `sre` section, about 90 minutes, one switch) is the separate variant.
- **P9 fails later because the subscription isn't registered:** get it registered, and check that
  `rg-<prefix>-sre` holds no agent: `az resource list -g rg-<prefix>-sre --subscription <SUB> --query "[?type=='Microsoft.App/agents'].name" -o tsv`
  prints nothing (or the group does not exist). Then run `-Execute -From P9 -Force` with the SRE
  switches. A rerun retries P9.1 (the preview) as it is, but a failed P9.2 (the paid create) is
  not retried until you have inspected it and pass `-Force`; with `-From P9`, `-Force` does not
  re-run the earlier steps.

### Snapshot and parity (read-only)

```powershell
$target = @{ SubscriptionId = '<SUB>'; TenantId = '<TENANT>'; SkinPath = '<PRIVATE>\arc-skin.json' }
.\scripts\Export-ArcDemoInventory.ps1 @target -OutputPath <PRIVATE>\evidence\inventory-before.json
.\scripts\Test-ArcDemoParity.ps1 @target -SnapshotPath <PRIVATE>\evidence\inventory-before.json -Feature RealSql, Sre
```

The snapshot records names, types, sizes, power states, associations, alert and
workbook definitions, policy/budget/Defender state, onboarding-credential
metadata, the Arc machines' tags and the retained manifest's fleet. It never reads a secret. A denied or
failed read is recorded verbatim in its section and the script exits 1.
Take one before a teardown and one after a rebuild.

The parity check compares a snapshot (or a fresh read) with
[`config/expected-inventory.json`](../config/expected-inventory.json) and the
manifest's fleet, exiting 0 only when every check passes. That includes the `role` and
`osTier` tags of each Arc machine against the manifest, when both sides recorded them,
and the lab tags (owner, purpose, costcenter, env) on the NAT gateway and public IP that
Activate recreates. Run it while the estate
is Active (parked estates have no NAT gateway). Update the expected list in the
same change that adds or removes a named object.

`-SnapshotPath` accepts only a snapshot that `Export-ArcDemoInventory.ps1` wrote
(`workload: arc-demo-inventory`, `schemaVersion: 1`); a snapshot from any other tool is
rejected, so take the before/after pair with the export script above.

The onboarding-application rows (`snapshot/onboardingApp`, `tenant/onboarding-app`,
`tenant/no-residual-credentials`, `tenant/no-long-lived-credentials`) read Microsoft Graph.
When Graph answers with a continuous access evaluation challenge
(`TokenCreatedWithOutdatedPolicies`), the scripts retry the call once without the CAE
capability; if that cannot clear it, those rows fail with the hint in their message while
every Azure row passes. That is not an estate fault: set
`$env:AZURE_IDENTITY_DISABLE_CP1 = '1'` in the shell, or `az logout` then
`az login --tenant <TENANT>`, and run the parity check again
([troubleshooting](troubleshooting.md#microsoft-graph-calls-fail-with-a-continuous-access-evaluation-challenge)).
Observed on 5 November 2026: 3 of 57 checks failed with the cached token and 57 of 57
passed with the variable set, in 151 seconds.

## 4. Validate, then rehearse

```powershell
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
.\scripts\Test-ArcDemoReadiness.ps1 @target -DesiredState Ready -OutputFormat Json -TimeoutSeconds 600 `
  -OutputPath "<PRIVATE>\evidence\readiness-$stamp.json"
$LASTEXITCODE
```

Exit 0 means required infrastructure/monitor checks pass, 1 is fail/error, 2 is
still pending. `-OutputPath` writes the same JSON to a file (creating its folder) and
leaves the exit code alone, so one run gives the timestamped evidence; it names the
subscription and tenant, so keep it in the private folder, outside source. Check policy, Defender,
Update Manager assessment completion, CT inventory and optional workload behavior
in their own surfaces; a provisioned extension is not proof of telemetry or
completed assessment. Policy scores and CT cycles may take substantially longer
than infrastructure provisioning.

For Linux, inspect direct sensor health separately from MDE extension state.
Diagnostics found healthy/licensed sensors in passive mode with
real-time protection disabled, plus an extension/direct-health
event-provider discrepancy that remained. A Monitor pass is not active AV or full EDR proof.

Rehearse the [25-28 minute Arc story](runsheet.md) from the runsheet you
[prepare next](#prepare-the-local-presenter-guide). The optional companion
SRE repo consumes these existing alerts; it does not replace the standalone Arc
operations plane. Reset/induce faults only as deliberate scenario
actions. Do not claim Arc SQL validation: the nested guest is experimental
and license-only; see [SQL stance](sql-arc-spike.md).

## Prepare the local presenter guide

Do this after deployment or activation has succeeded and an independent Active
readiness check passes ([section 4](#4-validate-then-rehearse)). You then present
from `.local/presenter-runsheet.md`, top to bottom; no customer customization or
ID lookup is required. Generating it changes no deployment or lifecycle behavior.

Plain Markdown cannot interpolate an external JSON file. The offline
`scripts\New-PresenterRunsheet.ps1` fills the single tracked `docs\runsheet.md`
template from `.local\demo-context.json`. The entire `.local/` folder is ignored.
Capture the following **nonsecret** fields from the explicit setup inputs and
actual deployment outputs/saved evidence, never CLI defaults or guessed IDs:

| Field | Source |
| --- | --- |
| `schemaVersion` | Numeric `1` |
| `subscriptionId`, `tenantId` | The target you confirmed |
| `recordedAtUtc` | UTC timestamp of the context/evidence being saved, not the generation time. The build wrapper's P10 uses the `checkedAtUtc` of the last passing P7 readiness evidence (when the estate was last seen healthy), and the current time only when there is no such evidence |
| `resourceGroups` | Object with actual `arc` and `infra` group names |
| `workspaceResourceId`, `workbookResourceId` | Exact workspace and saved Estate Overview workbook IDs |
| `windowsMachineResourceId`, `linuxMachineResourceId` | Exact monitored Arc machine IDs selected for the tour, not backing VM IDs |
| `heartbeatAlertResourceId`, `actionGroupResourceId` | Exact heartbeat rule and action group IDs |
| `lobMachineName` (optional) | The separately prepared LOB host; omit if not part of this demo |
| `sqlMachineResourceId` (optional) | Actual prepared SQL host Arc ID, with adjacent verified `sql-engine-status.json` from [real SQL Status](sql-engine-workload.md); omit until actually prepared |
| `sqlIncidentAlertResourceId` (optional) | Exact prepared SQL log-alert ID; requires the SQL host/proof above. Adds a concrete alert link, not an alert-delivery or investigation claim |
| `lobIncidentAlertResourceId` (optional) | Exact prepared LOB log-alert rule ID; requires `lobMachineName`. Adds a concrete alert link, not an alert-delivery or investigation claim |
| `nestedSqlMachineResourceId` (optional) | Exact Arc machine ID of the nested SQL guest; enables the experimental nested Arc SQL beat. A link, not proof of current state: you judge the beat by the live status and last collected time |
| `nestedSqlInstanceResourceId`, `nestedSqlParentMachineResourceId` (optional) | The guest's Arc-enabled SQL Server instance and its Hyper-V parent Arc machine; each requires the nested guest above |
| `dataCollectionRuleResourceId` (optional) | Exact core data collection rule ID, opened read-only in the "how the data gets here" beat |
| `machineIntelligenceWorkbookResourceId`, `complianceWorkbookResourceId` (optional) | Exact IDs of the original Machine Intelligence Center and Compliance, Security and Governance workbooks, used in the "show me one server" and "safe and up to date" chapters |
| `assetInventoryWorkbookResourceId`, `sqlEstateWorkbookResourceId` (optional) | Exact IDs of the Asset Inventory and SQL Estate workbooks: the optional extra minute in the estate chapter and the database chapter. Without them the runsheet skips those steps and says so |
| `capacityWorkbookResourceId`, `optimisationWorkbookResourceId` (optional) | Actual published IDs from the scoped [operational workbook setup](#optional-capacity-and-optimisation-workbooks); never preview or draft IDs. Adds optional links, not current-health or savings proof |
| `companionSreRunsheetPath` (optional) | Absolute path to the companion's actual generated guide; linked only if it exists |

The ordered build wrapper's P10 captures these for you. It writes every field above that it can verify
against Azure, including the data collection rule, the four original workbooks (found by their
`workbookTag`) and the nested guest with its SQL instance and parent, and it prints and records the
optional chapters it left out because the resource was not found. Fill in by hand only what it cannot
know, such as the LOB alert rule.

Write the values once, then run:

```powershell
# $context contains only the fields above, from your setup inputs and saved outputs.
New-Item -ItemType Directory -Path .\.local -Force | Out-Null
$context | ConvertTo-Json -Depth 4 | Set-Content .\.local\demo-context.json
.\scripts\New-PresenterRunsheet.ps1
```

No sign-in, Azure read/write, guest command or health check occurs in generation.
Pass `-AbsoluteLocalLinks` when you will copy the generated runsheet away from the
repository: the companion-guide and saved SQL-proof links then become absolute file
links instead of paths relative to `.local`.
Missing/foreign/malformed IDs fail explicitly before replacing the output.
The context timestamp is printed prominently: old evidence is not current health.
The generator does not read a credential store, copy a whole deployment manifest
or retain passwords, recipient emails, tokens or private configuration files.

Refresh the context and regenerate after preparation changes the resources or
selected hosts. An activation that leaves telemetry pending is not ready to
present from: poll readiness under the normal contract first. A missing
companion guide produces a plain note in the runsheet, not a broken or guessed
relative path.

### One page for the whole demo (optional)

To run the Arc half and the SRE half from one page, add the companion's actual generated
guide as `-SreGuidePath` (an absolute local path; the SRE guide is read, never changed):

```powershell
.\scripts\New-PresenterRunsheet.ps1 -AbsoluteLocalLinks -SreGuidePath <absolute path to the generated SRE guide>
```

It still writes `.local/presenter-runsheet.md` as before and also
`.local/full-demo-runsheet.md`, which is untracked like everything under `.local/`:

1. A **Whole demo in order** table: the Arc clock times from the chapter headings, then the SRE
   steps, with the live-fault points (say GO after chapter 7 has shown the alert rules, then run
   Prepare yourself; fire SQL, then LOB; fire T09 with your own Review click; Restore).
2. The Arc guide as generated, up to and including **Continue with the SRE half**.
3. **The night shift (SRE half)**: the SRE guide's own text from *This afternoon: verified
   existing investigations* through step 6, byte for byte, with only its numbered steps headed
   **SRE step N**. Its step 7 (the close) becomes a one-line pointer.
4. The single close, **The close: the Monday answers**, then the prepared answers, fallback
   queries and notes.

The generator stops without writing either page when the SRE guide has no *This afternoon*,
*Live faults* or steps 1 to 7 once each, in order, so a changed SRE guide is noticed rather than
spliced blindly. Regenerate whenever either guide changes. The Arc template stays the single
source: the combined page adds no presentation text of its own beyond the table and the
part titles.

## Optional capacity and optimisation workbooks

These are optional read-only engineer surfaces after setup, chapters 5 and 6 of the
25-28 minute story rather than additional workload infrastructure.
They reuse existing `Perf`/`InsightsMetrics` and Arc inventory; the views make no
guest, SQL, extension, power, price or schedule changes. The one collection change
is the Linux memory and disk counters in the core DCR, which
replaced three placeholder names that were never valid for Linux AMA.
What each section shows, the evidence rules and the thresholds are in the
[workbook reference](operational-workbooks.md). DR and Azure Migrate assessment
are outside this demo.

The scoped entry point defaults to **Preview**, which verifies the explicit
tenant/subscription, reads only the existing workspace/Arc group and the
deterministic workbook target, then returns rendered JSON with `published=false`.
It does not invoke ARM deployment or ARM what-if. It never silently registers a
provider or changes CLI defaults. Failed/denied/unknown reads stop the operation.
Use the same confirmed prefix/skin; an explicitly supplied missing skin fails.

```powershell
$workbookTarget = @{
    SubscriptionId = '<SUB>'; TenantId = '<TENANT>'
    NamePrefix = '<CONFIRMED_PREFIX>'; SkinPath = '<PRIVATE_SKIN_PATH>'
    WorkspaceResourceId = '<EXISTING_LAW_RESOURCE_ID>'
}
.\scripts\Set-OperationalWorkbook.ps1 @workbookTarget -Purpose capacity
.\scripts\Set-OperationalWorkbook.ps1 @workbookTarget -Purpose optimisation
# Preview publishing: still no writes.
.\scripts\Set-OperationalWorkbook.ps1 @workbookTarget -Purpose capacity -Action Deploy -WhatIf
# Review copies: a separate "(draft)" resource; the published workbook stays intact.
.\scripts\Set-OperationalWorkbook.ps1 @workbookTarget -Purpose capacity -Draft -Action Deploy
.\scripts\Set-OperationalWorkbook.ps1 @workbookTarget -Purpose optimisation -Draft -Action Deploy
# Promotion after review: the same command without -Draft replaces the published workbook in place.
.\scripts\Set-OperationalWorkbook.ps1 @workbookTarget -Purpose capacity -Action Deploy
.\scripts\Set-OperationalWorkbook.ps1 @workbookTarget -Purpose optimisation -Action Deploy
# Remove only an owned draft (no Arc roster is read).
.\scripts\Set-OperationalWorkbook.ps1 @workbookTarget -Purpose capacity -Draft -Action Remove
```

Actual publication is a separate step from the preview, confirmed by ShouldProcess.
`-DisplayUtcOffsetHours` sets the default display time zone of the scheduling heat-map
(the workbook selector can change it) and the clock stamped on each workbook's roster
footer, which names the offset (for example *UTC+10:30*) instead of calling a local time UTC.
Pass the offset the workbook already carries when republishing in place, or its times shift.

Only the selected shared workbook is created/updated by the small Bicep module,
with an exact-content readback. Stable IDs are derived from workspace/purpose
(drafts use their own ID, a `lifecycle: draft` tag and a banner);
a foreign existing workbook is never adopted. No whole-lab deployment, IAM or
repair is used. Workbooks survive parking with the workspace, contain no active
jobs and disappear with the Arc group on a normal removal. Existing
lifecycle/readiness gates are unchanged. Re-publishing changed source or
refreshing roster/topology is a deliberate publish, not an incidental wake. The roster
and the Arc tags it shows are a snapshot taken when the workbook is published, so a
later onboarding, tag repair or new host needs another publish. The ordered build
wrapper publishes both workbooks once, after the guest exists (its P6).
The roster is bounded to 1-50 exact Arc IDs because every item query embeds it.
Each workbook links to the other (a draft to the draft, a published workbook to the published one), so publish both
for the links to resolve; the portal URL carries the confirmed tenant.

**Coverage before conclusions:** each table starts with every selected Arc ID,
including hosts without samples. One canonical source is selected per host and
metric across the window, source names and observed hours stay visible, missing
values are null (never zero), invalid samples warn, and the column charts leave
absent intervals blank instead of drawing zeros. The default window is 14 days because the lab
runs sporadically; coverage is observed one-minute bins, not uptime or an agent SLA.
Evidence is adequate only with the selected observed hours (default 3, an illustrative
setting for an on-demand lab) and 80% sampling while active, so newly collected Linux memory
and disk read as thin for its first few running hours. Low CPU alone never yields a sizing recommendation, and SQL host
telemetry does not establish engine capacity, database performance or licence needs.
Thresholds (CPU 80%, sustained 30 minutes, memory 85%, disk free 15%, low CPU P95
20%) are editable, labelled illustrative triage values, not right-sizing or
availability guarantees; the fixed constants are listed on each workbook's
*Evidence and method* tab.

**Topology and ownership:** the roster contains exact Arc IDs only, never their
Azure backing-VM duplicates. The nested guest is declared once in the private
skin's `nestedSqlGuest` block (parent VM and Arc machine name); the script adds
the pair to the roster as a declared parent and guest. A guest that is not yet an
Arc machine in the group is skipped with a warning and appears after onboarding
and a republish; a disconnected guest is still listed and reads *No telemetry*
until it reports. Any other machine is `unclassified` unless an optional private
`-TopologyPath` JSON declares it: `{"schemaVersion":1,"machines":[...]}`, each
entry with `resourceId`, `layer` (`parent`, `guest` or `standalone`) and, for
guests only, `parentResourceId` referencing another selected, explicitly classified
parent. A conflict between the file and the skin is an error. Declared topology is a
relationship, not physical hardware capacity: no hardware totals are calculated and
parent and guest measurements are never added. A parent's own counters do not reflect
its guest's load, so a quiet parent is insufficient evidence, not headroom. The
optimisation view reads current `owner`/`costcenter`/`role` tags through Resource
Graph for those exact IDs. Empty/missing ARG results are missing inventory evidence,
not proof that a resource or owner is absent; query failures must be reported.

The optional cost scenario is typed into the workbook for one selected non-guest
workload: `baseline x eligible share x hours off / 168`, labelled illustrative and
not billing, a price, a calendar month, realised savings or a safe shutdown schedule.
Fixed, licensed, retained-storage, monitoring and security costs stay outside it.
No price API, inferred currency, estate multiplication, or stop/delete/schedule
action is provided.

After actual publication, save only the returned published workbook IDs as the
optional context fields above and regenerate your runsheet.
Do not add preview or draft IDs or claim portal rendering has been observed from
source validation alone. Documented workbook deployment and scope conventions:
[programmatic workbooks](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-automate)
and [workbook resource templates](https://learn.microsoft.com/azure/templates/microsoft.insights/2023-06-01/workbooks).

Local Pester covers rendering, scoping, roster and topology guards, size bounds,
draft handling, scenario arithmetic and the portal layout rules
(`tests/OperationalWorkbooksLayout.Tests.ps1`). `tests/OperationalWorkbookQueries.Tests.ps1`
is deliberately opt-in: pass explicit workspace/subscription/tenant via
`New-PesterContainer -Data` to execute the production item queries read-only
against deterministic literal tables. It ingests nothing, touches no guests and
covers spikes versus sustained pressure, missing, invalid and thin evidence, parked
gaps, Linux counter names and pseudo mounts, separate parent/guest rows and the
scenario arithmetic. Normal CI skips those Azure-dependent tests; a local mock
pass does not imply KQL execution or a published workbook.

## 5. Park and wake

```powershell
.\scripts\Hibernate-ArcDemo.ps1 @target -WhatIf
.\scripts\Hibernate-ArcDemo.ps1 @target
.\scripts\Test-ArcDemoReadiness.ps1 @target -DesiredState Hibernated
.\scripts\Activate-ArcDemo.ps1 @target -WhatIf
.\scripts\Activate-ArcDemo.ps1 @target
```

Hibernation parks all VM/AKS/Container App compute in the explicitly targeted demo
infra group, even if deployment manifests, OS metadata or skin drift; drift warns.
It verifies deallocation/AKS stop/inactive revisions before safe NAT/PIP removal.
Foreign/shared bindings skip only networking with a loud residual-cost warning.
Data, identities and fault flags remain. Failed compute attempts do not block
attempts on other hosts/workloads; unknown/denied final power is not success.
Hibernate prints a time-stamped line for each phase and takes the same optional
`-ResultPath` as Activate (an existing private directory); allow about 7 minutes
(observed 6 min 56 s and 7 min 16 s on eight VMs). The `-WhatIf` of Hibernate and of
Activate lists what each workload would do instead of one generic line; Hibernate's
takes about 80 seconds because it reads the full inventory first.
Activation restores outbound NAT first, then starts retained workloads. Every run
verifies the hosts, including already-connected ones, without restarting anything:
one shared wait with a 12-minute global deadline (`-GuestCheckMinutes`) passes a host
when its VM is running, Arc is `Connected` and, for a monitored host, a Heartbeat was
generated after the VM start. No Run Command is used for host checks by default, so a
VM extension update that is still `Updating` (a warning, never a gate) cannot stall the
wake; expect about 12-15 minutes (observed 11 min 55 s). The Arc status itself lags: Arc
machines keep reading `Connected` for 11-16 minutes after a stop and then read
`Disconnected`, so only the Heartbeat after the start decides a host. A host with no
Heartbeat at the deadline is pending
for that host only; a stopped VM or an Arc identity that never connects fails. Opt in
to Run Command guest checks with `-GuestChecks WhenStalled|Always` (Windows Arc
`himds`/`MonAgentCore`, Linux services) and to service restarts with
`-RepairStalledAgents`; both share the same deadline. The nested SQL guest start keeps
its Run Command concurrently with a five-minute budget. Per-host evidence records
`method`, `startedAtUtc`, `lastHeartbeatUtc` and `extensionStates`.
Telemetry-only pending does not fail activation, but recheck it through
readiness before you present or start the dependent SRE flow.
Default assessment submissions cover newly started/waking Arc hosts only;
already-active retries do not resubmit. `-AssessPatches` explicitly requests
all-host assessments (including assessment-phase retries). Use optional `-ResultPath`
in an existing private directory to preserve per-host outcomes, and distinguish
script completion from Monitor Ready and asynchronous assessment completion.
It does not reset faults. Optional AKS can take longer and
requires a 15-30 minute stop/start separation; capacity is not guaranteed.
Nightly VM auto-shutdown is not whole-lab hibernation. VMs can also be
deallocated outside these scripts: the DevTest auto-shutdown schedule (19:00 by
default; Deploy owns it and sets it again on every run, so set `operations.autoShutdownTime`
in the skin, or `autoShutdownTime` in the build config, before the Deploy to keep a later
time) and, in some subscriptions, governance automation that deallocates VMs
on its own schedule (observed nightly at about 02:17). Neither starts anything
again, so a stopped fleet after a quiet night is expected, not a fault. Run
Activate, which starts whatever is stopped, rather than repairing hosts by hand.
A governance automation can also convert a parked estate's disks to Standard HDD; the
next Deploy then refuses the tier
([troubleshooting](troubleshooting.md#the-os-disk-tier-changed-by-itself)).

Retain runtime target/skin/fleet inputs and deployment history outside git.
If SRE is attached, park that dependent layer first through its own maintained
procedure; on wake, restore Arc/Monitor and verify Ready before SRE resumes.
Hibernation is not cleanup: it does not delete groups, disks, Arc identities,
Key Vault secrets, onboarding credentials, DCRs or the workspace.
Its required acceptance covers parked compute/app state; NAT/PIP absence is a
non-required cost diagnostic. Exit 0 can therefore coexist with incomplete
network cleanup. Retained monitoring is not queried as a parking gate; actual
inspection/auth errors still fail rather than being misreported as absence.
Use normal lifecycle `-WhatIf`, not deployment Graph/Owner/quota preflight or
historical whole-group index comparisons. Exact network sharing is checked
before network writes. On partial failure, retry without redeploying or waking compute.
Enabled alerts can still evaluate/notify and incur charges; there is no automatic
pause/restore of their previous enabled state. Each Hibernate fires the Sev2
missing-heartbeat alert about 8-10 minutes after the VMs stop; it clears itself 16-21
minutes after it fired (once with every host still silent), and nothing is paused. That
is why a companion SRE agent is parked first. Other quiet-estate noise (Arc `Disconnected`,
Resource Health flaps, failed platform patch writes, activity-log entries for names that
are not in the subscription) is listed in
[lifecycle](lifecycle.md#what-still-happens-to-a-parked-estate).

## 6. Remove permanently

```powershell
.\scripts\Remove-ArcDemo.ps1 @target -WhatIf
.\scripts\Remove-ArcDemo.ps1 @target
.\scripts\Test-ArcDemoReadiness.ps1 @target -DesiredState Removed -OutputFormat Json
```

This deletes both demo groups and named policies/budget and verifies all their
absence. It is `ConfirmImpact='High'` and prompts: add `-Confirm:$false` when running
from an unattended or AI-driven shell (Deploy, Hibernate and Activate do not prompt;
the wrapper, `Prepare-NestedSqlParent.ps1` and the nested helpers do, like Remove).
A running nested parent gets one bounded graceful guest stop that warns
and continues if it fails; it is skipped when the guest never became an Arc machine, and a parent without
the Hyper-V role has nothing to stop. Allow **25-35 minutes**: a Container Apps environment sits in
`ScheduledForDelete` for about 25 minutes before its group can go. Remove prints `Still present: ...`
whenever that list changes and waits `-TimeoutMinutes` (default 60, at most 120). If the wait ends first
the deletion carries on in Azure and the script exits **2** (pending, not failed) without pruning or
touching Defender; run `Test-ArcDemoReadiness.ps1 -DesiredState Removed` until it passes, or rerun
the same Remove command, which skips what is already absent and then finishes those steps.
Two opt-in switches serve an intended clean same-prefix
rebuild: `-ForceDeleteWorkspace` first permanently deletes `law-<prefix>` (irreversible;
otherwise re-creating that name within 14 days recovers the old workspace and its
data) and `-PruneDeploymentHistory` deletes this demo's own old `arc-demo-<timestamp>`
deployment records after removal is verified. Defender pricing is preserved unless you
pass `-DisableDefender`. `-RemoveOnboardingIdentity` is separately opt-in and rejects
shared or ambiguous identities. Inspect remaining subscription/tenant resources and
delayed billing; completed group deletion does not guarantee zero charges.
Default Removed verification needs no deployment history or Graph lookup;
tenant identities/applications, shared services and soft-deleted vaults are
explicit exclusions. Active readiness also accepts the legacy `Ready` name.

## 7. Local development validation

```powershell
Invoke-ScriptAnalyzer -Path .\scripts -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path .\tests -CI
az bicep build --file .\bicep\main.bicep --stdout > $null
```

Pester is development-only, installed in CI; it is not a deployment dependency.
Fresh deploy, double deploy, park/wake and teardown/recreate remain separate
live smoke tests that need a disposable lab. See
[troubleshooting](troubleshooting.md) for known failure modes.
The [dated retained-estate wake/park evidence](nested-sql-demo.md) does not prove
fresh deployment, double-deploy idempotency, AKS lifecycle or full teardown/rebuild.
