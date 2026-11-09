# Private build folder

Everything private to one lab lives in **one folder outside git, outside every
worktree and outside your AI tool's session folders**. By default that is
`$HOME\arc-demo-private`, under your profile (a normal Windows profile limits it to you,
SYSTEM and administrators). A worktree or session can be deleted; this folder is what lets
a rebuild start from zero. Passwords, client
secrets and tokens are never written in plain text: the onboarding credential is
minted for one day and removed, and the passwords the estate cannot do without, the
generated VM admin password and (for the optional nested guest) the guest Administrator
credential you save once, are kept only as DPAPI-protected `.clixml` files
(readable by the same Windows user on the same PC;
elsewhere PowerShell does not encrypt them, so keep the folder user-only). Do not
copy them to another machine: to work from another PC or Windows account, pass the
VM admin password as `-AdminPassword`, or rebuild.

One plain-text exception, held for seconds: while Deploy submits the Bicep deployment, its
parameters file holds the VM admin password in your temp folder (a normal Windows profile
limits it to you, SYSTEM and administrators). Deploy submits with `--no-wait`, deletes the file as soon as Azure
accepts the request and again in a `finally` on any failure, and never writes it into the
private folder.

## Set up the whole demo

Run this from the repo root in `pwsh`, after `az login --tenant <TENANT_ID>`. It creates the
private folder, clones the companion repo that holds the SRE half, writes the two private
skins and the build config, and checks the SRE skin offline. Put your IDs in the first line.
Only `build.json` and `arc-skin.json` must exist before the first run (and `sre-skin.json`
for the SRE half); the wrapper creates the rest when a step needs it (the last column of the
table below says when).

```powershell
$sub = '<SUBSCRIPTION_ID>'; $tenant = '<TENANT_ID>'
$private = Join-Path $HOME 'arc-demo-private'   # outside git, every worktree and every AI-tool session folder
$sreRepo = Join-Path $HOME 'sre-agent-demo'     # a clone of the companion repo; any folder works
New-Item -ItemType Directory -Force -Path $private | Out-Null
if (-not (Test-Path $sreRepo)) { git clone https://github.com/corey-skapin/sre-agent-demo $sreRepo }

# Arc skin: your alert e-mail, this PC's time zone for the 19:00 shutdown, and the Container App the SRE half needs
$email = az account show --query user.name -o tsv   # the signed-in account; if it is not an address, replace this line with $email = '<the address you were given>'
if ($email -notmatch '@' -or $email -match '#EXT#') { throw 'Set $email to a real e-mail address first.' }
$arc = Get-Content .\config\demo-skin.json -Raw | ConvertFrom-Json
$arc.notifications.email = $email
$arc.operations.autoShutdownTimezone = (Get-TimeZone).Id
$arc.workloads.deployContainerApps = $true
$arc | ConvertTo-Json -Depth 10 | Set-Content "$private\arc-skin.json" -Encoding utf8

# SRE skin: the clone's example, matched to the Arc skin
$sre = Get-Content "$sreRepo\config\demo-skin.json" -Raw | ConvertFrom-Json
$sre.azure.namePrefix = $arc.azure.namePrefix
$sre.azure.location = $arc.azure.location
$sre.labels.agentName = "sre-$($arc.azure.namePrefix)"
$sre | ConvertTo-Json -Depth 10 | Set-Content "$private\sre-skin.json" -Encoding utf8

# Build config: the full-build example, pointed at the clone
$build = Get-Content .\config\build-plan.example.json -Raw | ConvertFrom-Json
$build.sre.repoPath = $sreRepo
$build | ConvertTo-Json -Depth 10 | Set-Content "$private\build.json" -Encoding utf8

# Check the SRE skin offline (no Azure call; it stops with an error if the skin is invalid)
& "$sreRepo\scripts\Initialize-SreConfiguration.ps1" -SubscriptionId $sub -TenantId $tenant -SkinPath "$private\sre-skin.json" | Out-Null
```

Then run the plan: `.\scripts\Invoke-ArcDemoBuild.ps1 -SubscriptionId $sub -TenantId $tenant -BuildConfigPath "$private\build.json"`.
Nothing should be blocked. What the block decides, and what it leaves alone:

- **Arc skin.** Every value keeps the shipped default (region `australiaeast`, name prefix
  `arc-demo`, shutdown `1900`, VM size `Standard_B2as_v2`) except three. The alert e-mail is
  the signed-in account's address. The shutdown time zone is this PC's: the shipped Cen.
  Australia Standard Time is the author's, and 19:00 there is morning in Europe, which would
  stop the VMs in the middle of a working day. (On Windows, `(Get-TimeZone).Id` is the
  Windows time zone name the schedule expects; elsewhere it is an IANA name, and real builds
  are untested there, so use the Windows name.) And `workloads.deployContainerApps` is `true`:
  the SRE half needs the Container App `ca-<prefix>-fault`, or P9 stops after hours of build.
  The Container Apps environment adds roughly 17-23 minutes. To use another region, shutdown
  time, prefix or VM size, set it on `$arc` before the file is written; the SRE skin follows
  the prefix and region. The SRE half works only in an
  [SRE Agent supported region](https://learn.microsoft.com/azure/sre-agent/supported-regions).
- **SRE skin.** The clone's `config\demo-skin.json` with `azure.namePrefix`, `azure.location`
  and `labels.agentName` matched to the Arc skin, as the companion repo's reskin guide asks.
  Its other values suit the default scenarios.
- **`build.json`.** The full-build example (real SQL, the SRE half and a LOB host) with
  `sre.repoPath` set to the clone. `sre.skinPath` is `sre-skin.json`, which resolves against
  this folder like every relative path in the file. As shipped, the plan needs
  `-ApproveCostStart`, `-AcceptSqlDeveloperTerms` and `-ApproveSreCreation`. A first SRE build
  also needs `-ApproveSubscriptionGrant`, which the plan reminds you of under the command
  instead of listing. The placeholder `sre.repoPath` would block P8 and P9 and stop `-Execute`
  from starting, which is why the block replaces it.
- **Arc only.** Skip the clone, the SRE skin and the last line, leave `deployContainerApps` at
  its shipped `false`, and in `build.json` delete the `realSql` and `sre` sections and clear
  `presenter.lobMachineName`: replace the `$build.sre.repoPath` line with
  `$build.PSObject.Properties.Remove('realSql'); $build.PSObject.Properties.Remove('sre'); $build.presenter.lobMachineName = ''`.
  Nothing is blocked, the plan is about 90 minutes and needs only `-ApproveCostStart`.
- **Nested guest.** Off. To build it, set the skin's `nestedSqlGuest` block as
  [nested-sql-demo.md](nested-sql-demo.md) shows and [save its credential](#saving-the-nested-guest-credential);
  the recipe generates the password, so nobody types one.

| File or folder | What it is | Written by, and when |
| --- | --- | --- |
| `build.json` | Wrapper config, copied from [`config/build-plan.example.json`](../config/build-plan.example.json) | you, before the first run ([setup block](#set-up-the-whole-demo)) |
| `arc-skin.json` | Private Arc skin: prefix, region, notification e-mail, workload flags, `nestedSqlGuest`, optional fleet path | you, from `config/demo-skin.json`, before the first run ([setup block](#set-up-the-whole-demo)) |
| `arc-fleet.json` | Optional private fleet named by the skin's `workloads.onPremFleetPath` | you, only if the skin names it |
| `sre-skin.json` | Private skin for the companion SRE repo: a copy of its `config\demo-skin.json` with `azure.namePrefix`, `azure.location` and `labels.agentName` matched to the Arc skin | you, only with the companion repo ([setup block](#set-up-the-whole-demo)) |
| `nested-sql-build.json` | Nonsecret inputs of the nested guest build (see [nested-sql-demo.md](nested-sql-demo.md)) | the parent preparation step (P3) when it passes, so it does not exist before then (the plan still lists P4); or you, by hand, for a parent prepared another way |
| `vm-admin-credential.clixml` | The generated VM admin password (DPAPI-protected SecureString), for reruns of P2 when the Key Vault cannot be read from this PC or a build failed part way | `Deploy-ArcDemo.ps1` at P2, before any Azure write |
| `nested-guest-credential.clixml` | Optional: the nested guest's Administrator credential (DPAPI-protected PSCredential) so P4 runs unattended. Without it P4 prompts, and a session that cannot prompt stops before anything starts | you, once ([recipe](#saving-the-nested-guest-credential)); the wrapper only reads it |
| `build-state.json` | Which steps are done, with attempts and evidence paths | the wrapper, at the first `-Execute` |
| `evidence/` | One JSON file per step, readiness results, inventory snapshots and `media-acceptance.json`, the recorded licence acceptance for the installer media | the wrapper, `Export-ArcDemoInventory.ps1`, `Test-ArcDemoReadiness.ps1 -OutputPath` and the media scripts, when they first write evidence: do not create it by hand |
| `sre-backups/` | One new SRE configuration backup per SRE deployment | the wrapper, for the SRE deploy script (P9) |

Relative paths in `build.json` resolve against this folder. Use a separate
folder for each lab; the state file refuses a different subscription, tenant or
prefix.

## `build.json`

| Field | Meaning |
| --- | --- |
| `schemaVersion` | `1` |
| `arcSkinPath` | Private Arc skin (required) |
| `deployerPrincipalId` | Optional Entra object ID (your own), only when Graph sign-in lookup is blocked; it replaces that lookup and bypasses no permission check. See [the CAE entry](troubleshooting.md#microsoft-graph-calls-fail-with-a-continuous-access-evaluation-challenge) |
| `autoShutdownTime` | Optional `HHmm` override of the VM auto-shutdown time. Deploy owns this schedule and sets it again on every run, so a time changed by hand is reverted (per VM, as each VM module finishes). To keep a later shutdown, set it here or as `operations.autoShutdownTime` in the skin **before** the Deploy. Leave it empty unless the build would cross the default 19:00: the plan warns when the typical minutes plus a 50% allowance would |
| `nestedSqlBuildInputPath` | The nested guest's build inputs file listed above |
| `mediaManifestPath` | Optional override of the tracked `config/demo-media.json` (installer URLs, sizes and SHA-256 pins; nothing in it is secret). Leave it out to use the tracked manifest |
| `realSql` | Optional, and in the example: delete it for an Arc-only build, because it adds the SQL steps and needs `-AcceptSqlDeveloperTerms`. SQL host `machineName`, the full guest-local `isoPath` in a folder (for example `C:\DemoMedia\SQLServer2022-x64-ENU-Dev.iso`) and `stageMedia` (`false` when the ISO is already on the guest). When the wrapper stages the ISO the file name must match the manifest's `fileName` for `sql-server-2022-developer`, and the install is pinned to its `sha256` |
| `operationalWorkbooks` | Publish the capacity and optimisation workbooks (default `true`) |
| `sre` | Optional, and in the example: delete it for an Arc-only build. `repoPath` is your local clone of the companion repo [sre-agent-demo](https://github.com/corey-skapin/sre-agent-demo) (clone it anywhere; the example's placeholder is not a folder, so P8 and P9 stay blocked until you set it). `skinPath` is your private SRE skin, `sre-skin.json` in this folder (see the [setup block](#set-up-the-whole-demo)). `grantSwitch` is the parameter of the SRE deploy script that performs the alert-access grant (the wrapper passes it only when you pass `-ApproveSubscriptionGrant`, which a first SRE build needs). The SRE half also needs `workloads.deployContainerApps` set to `true` in the Arc skin before P2, and a subscription registered for Azure SRE Agent ([runbook](runbook.md#build-everything-in-order-optional-wrapper)) |
| `presenter` | Optional: the Windows and Linux Arc machines for the tour, and the LOB host (`lobMachineName`; clear it when you build no LOB app, or the runsheet says a LOB host was prepared) |

Leaving a section out skips its steps, with the reason shown in the plan.
Nested SQL steps follow the skin's `nestedSqlGuest`, not the build config.

## Saving the nested guest credential

The nested guest (P4) needs an Administrator credential. A
`[pscredential]` cannot be passed to `pwsh -File`, so an unattended run reads this
export. Create it once on the PC that runs the wrapper, with a generated password that
meets the guest contract (24 to 128 printable ASCII characters with an upper-case
letter, a lower-case letter, a digit and a symbol). Nothing is printed or stored in
the repo:

```powershell
Import-Module .\scripts\lib\Common.psm1
[pscredential]::new('Administrator', (ConvertTo-SecureString (New-StrongPassword -Length 24) -AsPlainText -Force)) |
    Export-Clixml -LiteralPath '<private folder>\nested-guest-credential.clixml'
```

Use a password of your own instead when the guest must keep a known one. To sign
in at the guest console, copy the password without printing it:
`(Import-Clixml '<private folder>\nested-guest-credential.clixml').GetNetworkCredential().Password | Set-Clipboard`.
The wrapper never writes or rotates this file.
Activate, Hibernate and Remove take no guest credential. A rebuilt guest needs a new file.

## What is checked

Only the basics: the file is JSON with `schemaVersion` 1, no unknown field, the
right value types, valid names and `HHmm`, and the folder is outside the git
worktree. The plan then reports, per step, a missing script, a parameter the
script does not accept, or a missing input file. There is no schema framework.

## Before deleting a worktree

Copy anything private that only exists in a worktree's `.local` folder (skins,
build inputs, media provenance, presenter context) into this folder first.
Old DPAPI guest-credential files belong to the old guest and are obsolete after
a rebuild; the new guest gets a new credential: replace `nested-guest-credential.clixml`
before the next P4.
