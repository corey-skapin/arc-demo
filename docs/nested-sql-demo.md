# Nested SQL demo: build, park, wake, remove

The primary path is a **scratch Windows Server 2022 guest with SQL Server 2022
Developer and Arc**. The repo-only rehearsal took **45m44s**, parked in **4m03s**,
woke in **2m41s**, and parked again in **3m02s**. Wake preserved the guest and Arc
identities, passed a real SQL query and extension/login checks, and uploaded fresh
inventory with four Online system databases. These are observed timings, not SLAs.

This is an Azure-hosted nested **demo**, not a production support claim. The
timings below rebuilt the guest on a parent that was prepared by hand. The
parent's size, data disk, Hyper-V role, network and media are now code
([Prepare the parent](#prepare-the-parent)), rehearsed end to end on a scratch
`Standard_D4s_v5`; a full from-zero rebuild through Deploy is not yet recorded
here. Use approved Windows/SQL
media and terms; Developer/Evaluation editions are not production licences.
The normal fleet's `MSFT_ARC_TEST=true` simulation is a separate path.

## Prepare the parent

The guest runs under Hyper-V inside one Azure VM, the **parent**. The fleet's
B-series sizes cannot run Hyper-V guests, so the parent needs a nested-capable
size (default `Standard_D4s_v5`), a data disk for the guest and installer media
(it becomes `D:`; this size has no temp disk, so the empty virtual DVD-ROM that holds `D:` is moved to `Z:`), the Hyper-V role, an internal
switch with a NAT, and the Windows Server 2022 Evaluation and SQL Server 2022
Developer ISOs. All of it is code:

| Part | Done by | Result |
| --- | --- | --- |
| Size, data disk, security type | `Deploy-ArcDemo.ps1`, from the skin's `nestedSqlGuest` block | `Standard_D4s_v5`, a 128 GiB `StandardSSD_LRS` disk at LUN 0, security type `Standard`; a later Deploy refuses to resize or detach them |
| `D:` volume, Hyper-V role, switch and NAT, ISOs, build input | `Prepare-NestedSqlParent.ps1` | `D:` (NTFS, `NestedSQL`), Hyper-V running, `NestedSqlSwitch` and NAT `172.31.240.0/24`, both ISOs hash-verified in `D:\NestedSQL\Media`, `.local\nested-sql-build.json` |

Security type `Standard` needs the subscription feature
`Microsoft.Compute/UseStandardSecurityType`. Without it Compute rejects the parent
partway through Deploy, after the other VMs exist (`BadRequest ... The value
'Standard' is not available for property 'securityType' until the feature
Microsoft.Compute/UseStandardSecurityType is registered`). `Test-Prerequisites.ps1`,
the build wrapper's P0 and Deploy check it read-only from the same list and never
register it. An authorized operator registers it once per subscription: `az feature
register --subscription <SUB> --namespace Microsoft.Compute --name
UseStandardSecurityType`, then `az provider register --subscription <SUB> --namespace
Microsoft.Compute --wait`. In the rebuild that found this the feature read `Registered`
at once and both steps took under a minute; the provider refresh is what propagates it.

Copy the selected skin to `.local\demo-skin.json`; set its `azure.namePrefix` to
the actual demo prefix, name an existing Windows fleet VM as the parent and enable:

```json
"nestedSqlGuest": {
  "enabled": true,
  "parentVmName": "sql-parent",
  "guestVmName": "sql-guest",
  "arcMachineName": "sql-guest"
}
```

Use actual names privately; the scratch guest and Arc names must match. The same
block drives Deploy, normal Activate, Hibernate and Remove and the optional
pair-only state helper. Both bundled skins leave it disabled. Optional
`parentVmSize`, `parentDataDiskGb` and `parentDataDiskStorageAccountType` replace
the defaults, for example to match an existing parent exactly.

If an unused alternative parent remains in the same infra group, explicitly list
its name under `operations.keepParkedVmNames` in the private skin, for example
`"operations": { "keepParkedVmNames": ["unused-image-parent"] }`. It must already
be deallocated and outside the active fleet. Whole-estate Activate leaves it
parked, readiness checks that state, and Hibernate still parks all group compute.
This does not permit starting unknown VMs or touching their nested guests.

With the lab Active (a fresh Deploy leaves it Active), preview and then prepare.
The subscription and tenant stay private:

```powershell
$prep = @{ SubscriptionId = $sub; TenantId = $tenant; SkinPath = '.local\demo-skin.json' }
.\scripts\Prepare-NestedSqlParent.ps1 @prep -WhatIf
.\scripts\Prepare-NestedSqlParent.ps1 @prep -AcceptWindowsEvaluationTerms -AcceptSqlDeveloperTerms -Confirm:$false
```

Each phase checks first and changes only what is missing, so a rerun on a
prepared parent mutates and restarts nothing. `-Phase` selects some phases;
Preflight always runs.

| Phase | Does | Skips or refuses |
| --- | --- | --- |
| Preflight | Read-only: exact context and inventory, VM state, lab Active | A parked lab (run the approved Activate first: it never starts compute without explicit outbound networking) or a VM that is mid-transition |
| Size | Deallocate, resize to the declared size, start again | Skips when already that size (Deploy declared it); refuses while a nested guest runs |
| Disk | Create and attach the declared data disk at LUN 0 | Skips when attached as declared; refuses when LUN 0 or the disk name belongs to something else, and never resizes, converts or moves a disk |
| Volume | Initialise the blank LUN 0 disk as `D:` (NTFS, `NestedSQL`) with `VMs` and `Media` folders; a size without a temp disk leaves `D:` to the empty virtual DVD-ROM, which moves to `Z:` first | Skips when already so; refuses a `D:` that is another volume, including a DVD-ROM that holds a disc |
| HyperV | Install the role with management tools; the restart is issued from Azure (`az vm restart`), never from inside the guest | Skips when the role and hypervisor run; refuses while a nested guest runs, with Trusted Launch, or on an untested size (`-AllowUntestedSize`) |
| Network | Internal switch, host address `172.31.240.1`, NAT for `172.31.240.0/24` | Skips when matching; refuses a range that overlaps the Azure address space or a route, or conflicts with an existing switch or NAT |
| Media | Runs `Stage-DemoMedia.ps1` for both ISOs into `D:\NestedSQL\Media` | Skips both when present with the pinned size and SHA-256 |
| Verify | Read-only checks, including both ISO hashes; on a pass writes the build input | Never starts a VM; stops with an error when a required check fails |

- `-WhatIf` reads Azure only: no guest command, no start, no download.
- Staging media needs both `-AcceptWindowsEvaluationTerms` and
  `-AcceptSqlDeveloperTerms`. Acceptance is recorded privately and never assumed;
  both ISOs are pinned in `config\demo-media.json` and checked before use (see
  [media staging](sql-engine-workload.md#approval-fit-and-media)).
- It uses classic Run Command, so it does not consume the parent's 25 saved
  managed commands. Do not run it while Activate, Hibernate, Deploy or a nested
  build is using the parent.
- It stops at the first failing phase and keeps partial progress; fix the cause
  and rerun ([symptoms](troubleshooting.md#preparing-the-nested-sql-parent-stops)).
- The result object has `status` (`pass`, `pending` or `fail`), each phase as
  `satisfied`, `changed` or `skipped` with seconds, and the checks; `-ResultPath`
  saves it outside git.
- Observed on a scratch `Standard_D4s_v5` (Windows Server 2019 Gen2, Australia East,
  2 November 2026; timings, not SLAs). Creating and attaching the data disk took
  about 45 s; then Volume 2m11s, HyperV 5m56s (role install, restart from Azure,
  hypervisor check), Network 2m02s, Media 2m11s for both ISOs (5.78 GiB) and
  Verify 1m11s: about 14 minutes in all. A rerun on the prepared VM changed
  nothing and restarted nothing (5m26s, mostly Run Command round trips and
  hashing both ISOs). After a deallocate and start, Verify still passed 10 of 10
  but took 4m45s because both ISOs are read cold for the hash. By hand the same
  steps took about 31 minutes wall clock.

A parent prepared by hand needs no change: declare its actual size and disk in the
skin ([Deploy refuses a retained VM's size or data
disk](troubleshooting.md#deploy-refuses-a-retained-vms-size-or-data-disk)) and
Prepare only verifies it, without a restart.

When Verify passes it writes the build's nonsecret arguments to
`.local\nested-sql-build.json`, keeping other keys already in that file:
`SubscriptionId`, `TenantId`, `ParentVmId` (the Azure VM id), `Location`,
`WindowsIsoPath`, `SqlIsoPath`, `SwitchName`, `GuestAddress`, `Gateway`,
`DnsServer`, and `OnboardingApplicationId` (looked up by the display name
`sp-<prefix>-onboard`, which Deploy creates, or pass `-OnboardingApplicationId`).
For a parent prepared another way, write the same keys by hand; `Get-Help
.\scripts\New-NestedSqlDemo.ps1 -Full` lists these inputs. All IDs, addresses,
media paths and results stay outside git.

The build needs the onboarding application `sp-<prefix>-onboard`, which Deploy
creates when it is absent. Each build ensures the application's `Azure Connected
Machine Onboarding` role at the Arc resource group, adds a uniquely named one-day
application credential, delivers it only through the protected Connect parameter,
and removes that credential in `finally`, verifying the pre-build key IDs are
unchanged (the same `Initialize-DemoOnboardingIdentity` helper Deploy uses); the
credential value is never a build-file input. No vault or private-endpoint inputs
are needed. Do not rotate existing credentials, change Defender policy/pricing, or
rebuild a retained parent to wake the guest. The parent needs sufficient memory,
nested-virtualization support and space for the guest's 64-GiB OS and 32-GiB data
disks.

## Build

Run in PowerShell 7.4+ with the exact tenant/subscription already signed in.
Supply the approved retained/new guest Administrator credential from the secure
prompt or the DPAPI-protected export described in
[private-config.md](private-config.md#saving-the-nested-guest-credential), never in
JSON or command-line text:

```powershell
Import-Module .\scripts\lib\Common.psm1
$skinPath = '.local\demo-skin.json'
$skin = Get-DemoSkin -Path $skinPath
$guest = Get-DemoNestedSqlGuestConfig -Skin $skin
$prefix = Get-DemoSkinValue $skin 'azure.namePrefix' 'arc-demo'
$build = Get-Content .local\nested-sql-build.json -Raw | ConvertFrom-Json -AsHashtable
$build.ParentResourceGroup = "rg-$prefix-infra"
$build.ResourceGroup = "rg-$prefix"
$build.ParentVmName = $guest.ParentVmName
$build.VmName = $guest.GuestVmName
$build.VmRoot = "D:\NestedSQL\VMs\$($guest.GuestVmName)"
$saved = '<private folder>\nested-guest-credential.clixml'
$build.GuestCredential = if (Test-Path -LiteralPath $saved) { Import-Clixml -LiteralPath $saved } else {
    Get-Credential -UserName Administrator -Message 'Approved guest Administrator credential' }
$life = @{ SubscriptionId = $build.SubscriptionId; TenantId = $build.TenantId;
    SkinPath = $skinPath; NamePrefix = $prefix }
.\scripts\New-NestedSqlDemo.ps1 @build -SkinPath $skinPath -WhatIf
$result = .\scripts\New-NestedSqlDemo.ps1 @build -SkinPath $skinPath -Confirm:$false
$result | ConvertTo-Json -Depth 12 | Set-Content .local\nested-sql-result.json
```

Preview is not creation. The real invocation ensures the Arc-group onboarding
role, mints a one-day credential, creates
only a new named guest/root, waits for unattended setup, connects Arc, installs
SQL, enables the SQL extension in LicenseOnly mode, checks local SQL plus Azure
inventory, then removes the minted credential and verifies the original key IDs.
Cleanup runs after build failures too. It stops on a failed step; do not blindly
rerun the whole build against an existing guest.
The individual New/Wait/Connect/Engine/Enable/Test scripts support targeted
continuation through `Invoke-NestedSqlDemoStep.ps1`.

New Arc enrollment applies only the guest's ownership and identity tags:
`costcenter=demo`, `env=demo`, `owner=demo`, `purpose=arc-demo`, `role=sql`,
`osType=Windows`, `osTier=WS2022` and `inventory=arc`, alongside the existing
`ArcSQLServerExtensionDeployment=Disabled` onboarding tag. These are not parent
tags or proof of monitoring coverage: do not copy `monitorTier`, `defender`,
`updateManager` or `machineConfig` intent to this guest. Connecting an
already-connected guest does not retag it; an explicitly approved existing-guest
correction must merge tags and preserve unrelated tags, not replace the tag set.

| One-day-credential scratch-build step | Observed time |
| --- | ---: |
| Create/image/first boot | 10m37s |
| Wait for unattended setup | 5m12s |
| Arc connect | 6m16s |
| SQL install/version query | 8m25s |
| SYSTEM permission check/SQL-only unblock | 2m11s |
| Arc SQL extension | 4m48s |
| Azure SQL/database inventory | 2m38s |
| Local Windows/Arc/SQL/extension check | 42s |
| Build total | 42m21s |
| Total including credential handling | 42m30s |

Times exclude earlier failed attempts, debugging and removal. Scratch fixes were
cold DNS readiness, actual SQL bootstrap paths, parsing the agent block list,
and treating the first extension GET 404 as bounded creation lag.

The one-day-credential path was rebuilt from zero on 1 November 2026:
**42m21s** for the build (**42m30s** including credential handling). It passed
OOBE, Arc Connected, a real SQL Server 2022 Developer version query, extension
service/login checks and fresh Azure inventory with all four system databases
Online. The new credential was removed on successful completion. The final
park verified guest Off followed by parent deallocation; existing Arc/SQL
resources remained. The retained vault, original app credentials and other
guests were not changed.

## Hibernate and activate

Normal estate operations use the same skin. Preview first, then execute the
requested operation:

```powershell
.\scripts\Hibernate-ArcDemo.ps1 @life -WhatIf
.\scripts\Hibernate-ArcDemo.ps1 @life -Confirm:$false
.\scripts\Activate-ArcDemo.ps1 @life -WhatIf
.\scripts\Activate-ArcDemo.ps1 @life -Confirm:$false
.\scripts\Test-ArcDemoReadiness.ps1 @life -DesiredState Active -OutputFormat Table
```

Hibernate requests graceful guest shutdown before parking parent compute.
Whole-estate parking still attempts all compute if guest shutdown fails, with an
explicit consistency warning. Activate restores retained outbound NAT before
compute, starts the guest (a concurrent Run Command with its own five-minute
budget) and waits for its Arc connection inside the shared host wait; it does not
reconnect/reinstall SQL.

For **only this pair**, retaining shared networking and all other workloads:

```powershell
.\scripts\Set-NestedSqlDemoState.ps1 @life -State Stopped -Confirm:$false
.\scripts\Set-NestedSqlDemoState.ps1 @life -State Running -Confirm:$false
```

The pair-only helper refuses to park its parent after failed graceful shutdown.
Use normal Activate if whole-estate parking removed NAT. The live pair proof used
the retained parent; consolidated whole-estate wiring has mocked coverage and
the dated retained-estate rehearsals below, not a fresh full-estate rebuild proof.

The merged skin/Common **pair-only** path was also exercised live on
31 October 2026: wake, including Arc Connected, took 311.3 seconds; graceful
guest `Off` followed by parent-only deallocation took 143.5 seconds. The same
guest GUID, two disk paths and Arc VM ID were verified, SQL queried successfully,
and all four system databases remained Online with a fresh inventory upload.
The extension ARM state temporarily returned `Creating` before `Succeeded`;
bounded read-only observation settled it without reinstall or repair. No
fleet-wide lifecycle operation was run, and the pair was left parked.

The 1 November 2026 whole-estate rehearsals started eight managed hosts and the
configured nested guest while leaving the excluded Jumpstart parent parked.
The repeat wake used default patch-assessment settings, not the skip switch.
All eight monitored fleet hosts produced fresh Heartbeats: first post-wake
samples were generated after 3.2-3.7 minutes on Linux and 7.6-8.4 minutes on
Windows. The protected nested SQL query, extension service/login, fresh
four-database Azure inventory, real SQL orders worker and LOB health checks
passed.

After 56 minutes awake, all four actual workbook queries passed without errors.
The unchanged roster had 24 fresh metric rows, five stale historical disk rows,
13 missing rows and 24 history-gap warnings; fresh rows can still have gaps.
Full Active readiness nevertheless remained pending on six Linux AMA/Change
Tracking extension models reporting `Updating`. Default Activate did not
complete: Linux Run Command was blocked behind a VM extension update, rather
than missing Heartbeats. See [the Linux wait symptom](troubleshooting.md#linux-activation-waits-behind-a-vm-extension-update).
The Linux command was not resubmitted; no sensor repair or further wake was
attempted.

That rehearsal's final Hibernate passed in 7m42s, with graceful nested guest shutdown;
independent Hibernated readiness passed in 52 seconds. Direct reads verified all
nine VMs deallocated, no active Container App revisions and no NAT gateway or
public IP. This proves wake, SQL, fresh telemetry and parking, not clean
completion of default Activate or a fully Ready whole-estate demo.

On 2 November 2026 UTC, default Activate from merged main completed with exit 0
at 00:12:20, including all eight guest checks, nested guest Arc connection and
seven newly waking hosts' patch-assessment submissions. No Linux guest-check
stall occurred on this attempt. All eight selected VMs were running; the excluded
Jumpstart parent remained parked. Later read-only Active readiness at 00:25:48
was pending only on the six Linux AMA/Change Tracking extension models reporting
`Updating`, with fresh Heartbeats. This is not full Ready or completed patch
assessment proof. The estate was retained awake for separately approved work.

Arc Connected is not SQL readiness. After wake, run the parent-side SQL check:

```powershell
$parent = @{ SubscriptionId = $build.SubscriptionId; TenantId = $build.TenantId;
    ParentResourceGroup = $build.ParentResourceGroup; ParentVmName = $build.ParentVmName;
    ParentVmId = $build.ParentVmId }
.\scripts\Invoke-NestedSqlDemoStep.ps1 @parent -Step Test -GuestCredential $build.GuestCredential `
    -Parameters @{ VmName = $build.VmName; ExpectedArcResourceId = $result.ArcMachineId;
        TimeoutSeconds = 300; RequireSqlExtension = $true }
.\scripts\Test-ArcSqlDemoInventory.ps1 -SubscriptionId $build.SubscriptionId `
    -TenantId $build.TenantId -ResourceGroup $build.ResourceGroup `
    -ArcName $build.VmName -SqlResourceName $build.VmName
```

Allow extension/service and inventory startup lag; no manual login grants or
repair are a normal wake step. See [troubleshooting](troubleshooting.md).

## Remove

For a guest-only rebuild, wake its parent first and use the saved build identities:

```powershell
$saved = Get-Content .local\nested-sql-result.json -Raw | ConvertFrom-Json
.\scripts\Remove-NestedSqlDemo.ps1 @parent -VmName $saved.VmName -VmId $saved.VmId `
    -VmRoot $build.VmRoot -ArcMachineId $saved.ArcMachineId -ArcAgentVmId $saved.ArcAgentVmId `
    -SqlInstanceId $saved.SqlInstanceId -WhatIf
```

After approving the exact deletion, repeat without `-WhatIf`. This removes only
the guest, its private disks/root and matching Arc/SQL registrations; parent,
shared network, media and other workloads remain. The helper checks ownership
and refuses shared/reparse paths or unverified shutdown.

For **full demo removal**, use `Remove-ArcDemo.ps1 @life -WhatIf`, then execute
only when full removal is requested. It gracefully stops a running configured
guest before deleting the demo groups; it never wakes a parked parent just to
delete it. Full removal deletes the parent's guest disks with that parent's data
volume. Defender pricing and shared/tenant resources follow the existing
[lifecycle contract](lifecycle.md); parking is not zero-cost storage.

## Alternative: Jumpstart prebuilt image

The two approaches were deliberately raced. Scratch won the repeatable repo path;
Jumpstart remains a working, **manual** alternative, not a second build framework.

| Approach | Needed and broke | Repeatability and time evidence |
| --- | --- | --- |
| Scratch, primary | Prepared parent/media/network and onboarding application; corrected Server 2022 BCDBoot, DNS, bootstrap/block-list parsing and extension creation lag | One-day-credential build 42m30s; earlier run: build 45m44s, park 4m03s, wake 2m41s, repark 3m02s; retained identities and fresh SQL inventory |
| Jumpstart image | Acquire image and accept licence; finish OOBE, set Administrator password and static IP/DNS; private Arc/SQL setup; invalid `Stop-VM -Shutdown` and empty inline Run Command output were fixed | SQL 2019 Developer and Arc SQL inventory worked; setup remained manual. No comparable end-to-end build time was captured |

For Jumpstart, complete those manual steps, prevent guest IMDS access, and then
use generic `Connect-NestedSqlDemoGuest.ps1` through the step transport with the
actual image guest/Arc name and retained credential. SQL/extension helpers are
available, but do not reinstall an image's already-installed SQL merely to match
the scratch flow. Use the same skin for park/wake. The scratch teardown's private
disk/root checks intentionally do **not** authorize deleting an arbitrary image.

Observed image inventory included SQL 2019 Developer and AdventureWorksLT2019.
Migration metadata remained enabled despite a disabled extension request; no
assessment was launched. Neither path removes inherited Defender protection.
These observations do not prove production support or all Arc SQL features.
