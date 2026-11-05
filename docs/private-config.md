# Private build folder

Everything private to one lab lives in **one folder outside git, outside every
worktree and outside assistant session folders**. A worktree or session can be
deleted; this folder is what lets a rebuild start from zero. Passwords, client
secrets and tokens are never written in plain text: the onboarding credential is
minted for one day and removed, and the passwords the estate cannot do without, the
generated VM admin password and (for the optional nested guest) the guest Administrator
credential you save once, are kept only as DPAPI-protected `.clixml` files
(readable by the same Windows user on the same PC;
elsewhere PowerShell does not encrypt them, so keep the folder user-only). Do not
copy them to another machine: a hand-over needs `-AdminPassword` from whoever holds
the VM admin password, or a rebuild.

| File or folder | What it is | Written by |
| --- | --- | --- |
| `build.json` | Wrapper config, copied from [`config/build-plan.example.json`](../config/build-plan.example.json) | you |
| `arc-skin.json` | Private Arc skin: prefix, region, notification e-mail, workload flags, `nestedSqlGuest`, optional fleet path | you, from `config/demo-skin.json` |
| `arc-fleet.json` | Optional private fleet named by the skin's `workloads.onPremFleetPath` | you |
| `sre-skin.json` | Private skin for the companion SRE repo | you |
| `nested-sql-build.json` | Nonsecret inputs of the nested guest build (see [nested-sql-demo.md](nested-sql-demo.md)) | you, or the parent preparation step |
| `vm-admin-credential.clixml` | The generated VM admin password (DPAPI-protected SecureString), for reruns of P2 when the Key Vault cannot be read from this PC or a build failed part way | `Deploy-ArcDemo.ps1` at P2, before any Azure write |
| `nested-guest-credential.clixml` | Optional: the nested guest's Administrator credential (DPAPI-protected PSCredential) so P4 runs unattended. Without it P4 prompts, and a session that cannot prompt stops before anything starts | you, once ([recipe](#saving-the-nested-guest-credential)); the wrapper only reads it |
| `build-state.json` | Which steps are done, with attempts and evidence paths | the wrapper |
| `evidence/` | One JSON file per step, readiness results, inventory snapshots and `media-acceptance.json`, the recorded licence acceptance for the installer media | the wrapper, `Export-ArcDemoInventory.ps1`, the media scripts |
| `sre-backups/` | One new SRE configuration backup per SRE deployment | the wrapper, for the SRE deploy script |

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
| `realSql` | Optional: SQL host `machineName`, the full guest-local `isoPath` in a folder (for example `C:\DemoMedia\SQLServer2022-x64-ENU-Dev.iso`) and `stageMedia` (`false` when the ISO is already on the guest). When the wrapper stages the ISO the file name must match the manifest's `fileName` for `sql-server-2022-developer`, and the install is pinned to its `sha256` |
| `operationalWorkbooks` | Publish the capacity and optimisation workbooks (default `true`) |
| `sre` | Optional: `repoPath` of the local companion clone, its `skinPath`, and `grantSwitch`, the parameter of the SRE deploy script that performs the opt-in alert-access grant |
| `presenter` | Optional: the Windows and Linux Arc machines for the tour, and the LOB host |

Leaving a section out skips its steps, with the reason shown in the plan.
Nested SQL steps follow the skin's `nestedSqlGuest`, not the build config.

## Saving the nested guest credential

The nested guest (P4) needs an Administrator credential that you approve. A
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

Use your own approved password instead when the guest must keep a known one. To sign
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
