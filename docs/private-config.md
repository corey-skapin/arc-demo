# Private build folder

Everything private to one lab lives in **one folder outside git, outside every
worktree and outside assistant session folders**. A worktree or session can be
deleted; this folder is what lets a rebuild start from zero. It holds no secret:
passwords, client secrets and tokens are never stored. The guest credential is
prompted for, and the onboarding credential is minted for one day and removed.

| File or folder | What it is | Written by |
| --- | --- | --- |
| `build.json` | Wrapper config, copied from [`config/build-plan.example.json`](../config/build-plan.example.json) | you |
| `arc-skin.json` | Private Arc skin: prefix, region, notification e-mail, workload flags, `nestedSqlGuest`, optional fleet path | you, from `config/demo-skin.json` |
| `arc-fleet.json` | Optional private fleet named by the skin's `workloads.onPremFleetPath` | you |
| `sre-skin.json` | Private skin for the companion SRE repo | you |
| `nested-sql-build.json` | Nonsecret inputs of the nested guest build (see [nested-sql-demo.md](nested-sql-demo.md)) | you, or the parent preparation step |
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
| `deployerPrincipalId` | Optional Entra object ID, only when Graph sign-in lookup is blocked |
| `autoShutdownTime` | Optional `HHmm` override for the build window. Leave it empty unless the build would cross the VM auto-shutdown; it is passed to the base deployment |
| `nestedSqlBuildInputPath` | The nested guest's build inputs file listed above |
| `mediaManifestPath` | Optional override of the tracked `config/demo-media.json` (installer URLs, sizes and SHA-256 pins; nothing in it is secret). Leave it out to use the tracked manifest |
| `realSql` | Optional: SQL host `machineName`, the full guest-local `isoPath` in a folder (for example `C:\DemoMedia\SQLServer2022-x64-ENU-Dev.iso`) and `stageMedia` (`false` when the ISO is already on the guest). When the wrapper stages the ISO the file name must match the manifest's `fileName` for `sql-server-2022-developer`, and the install is pinned to its `sha256` |
| `operationalWorkbooks` | Publish the capacity and optimisation workbooks (default `true`) |
| `sre` | Optional: `repoPath` of the local companion clone, its `skinPath`, and `grantSwitch`, the parameter of the SRE deploy script that performs the opt-in alert-access grant |
| `presenter` | Optional: the Windows and Linux Arc machines for the tour, and the LOB host |

Leaving a section out skips its steps, with the reason shown in the plan.
Nested SQL steps follow the skin's `nestedSqlGuest`, not the build config.

## What is checked

Only the basics: the file is JSON with `schemaVersion` 1, no unknown field, the
right value types, valid names and `HHmm`, and the folder is outside the git
worktree. The plan then reports, per step, a missing script, a parameter the
script does not accept, or a missing input file. There is no schema framework.

## Before deleting a worktree

Copy anything private that only exists in a worktree's `.local` folder (skins,
build inputs, media provenance, presenter context) into this folder first.
Old DPAPI guest-credential files belong to the old guest and are obsolete after
a rebuild; the new guest gets a new credential.
