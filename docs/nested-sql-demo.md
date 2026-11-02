# Nested SQL demo: build, park, wake, remove

The primary path is a **scratch Windows Server 2022 guest with SQL Server 2022
Developer and Arc**. The repo-only rehearsal took **45m44s**, parked in **4m03s**,
woke in **2m41s**, and parked again in **3m02s**. Wake preserved the guest and Arc
identities, passed a real SQL query and extension/login checks, and uploaded fresh
inventory with four Online system databases. These are observed timings, not SLAs.

This is an Azure-hosted nested **demo**, not a production support claim. The
from-zero proof rebuilt the guest, **not** the prepared Azure parent, media,
Hyper-V network or onboarding application. Use approved Windows/SQL
media and terms; Developer/Evaluation editions are not production licences.
The normal fleet's `MSFT_ARC_TEST=true` simulation is a separate path.

## Prepare once

Keep the existing Windows Hyper-V parent, switch/NAT, mounted Windows Server 2022
and SQL Server 2022 media, and the onboarding application with its approved
permissions. Each build adds a uniquely named one-day application credential,
delivers it only through the protected Connect parameter, and removes that
credential in `finally`, verifying the pre-build key IDs are unchanged. No vault
or private-endpoint inputs are needed. Do not rotate existing credentials,
change Defender policy/pricing, or rebuild a retained parent to wake the guest.
The parent needs sufficient memory, nested-virtualization support and space for
the guest's 64-GiB OS and 32-GiB data disks.

Copy the selected skin to `.local\demo-skin.json`; set its `azure.namePrefix` to
the actual demo prefix and enable:

```json
"nestedSqlGuest": {
  "enabled": true,
  "parentVmName": "sql-parent",
  "guestVmName": "sql-guest",
  "arcMachineName": "sql-guest"
}
```

Use actual names privately; the scratch guest and Arc names must match. The same
block drives normal Activate, Hibernate and Remove and the optional pair-only
state helper. Both bundled skins leave it disabled.

If an unused alternative parent remains in the same infra group, explicitly list
its name under `operations.keepParkedVmNames` in the private skin, for example
`"operations": { "keepParkedVmNames": ["unused-image-parent"] }`. It must already
be deallocated and outside the active fleet. Whole-estate Activate leaves it
parked, readiness checks that state, and Hibernate still parks all group compute.
This does not permit starting unknown VMs or touching their nested guests.

Put the build's nonsecret arguments in `.local\nested-sql-build.json`: explicit
`SubscriptionId`, `TenantId`, retained `ParentVmId`, `Location`, parent-side
`WindowsIsoPath` and `SqlIsoPath`, `SwitchName`, `GuestAddress`, `Gateway`,
`DnsServer`, and `OnboardingApplicationId`. All IDs, addresses, media paths and
results stay outside git. The build obtains and removes the one-day credential;
the credential value is never a build-file input. `Get-Help
.\scripts\New-NestedSqlDemo.ps1 -Full` lists these inputs.

## Build

Run in PowerShell 7.4+ with the exact tenant/subscription already signed in.
Supply the approved retained/new guest Administrator credential through a secure
prompt, never in JSON or command-line text:

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
$build.GuestCredential = Get-Credential -UserName Administrator -Message 'Approved guest Administrator credential'
$life = @{ SubscriptionId = $build.SubscriptionId; TenantId = $build.TenantId;
    SkinPath = $skinPath; NamePrefix = $prefix }
.\scripts\New-NestedSqlDemo.ps1 @build -SkinPath $skinPath -WhatIf
$result = .\scripts\New-NestedSqlDemo.ps1 @build -SkinPath $skinPath -Confirm:$false
$result | ConvertTo-Json -Depth 12 | Set-Content .local\nested-sql-result.json
```

Preview is not creation. The real invocation mints a one-day credential, creates
only a new named guest/root, waits for unattended setup, connects Arc, installs
SQL, enables the SQL extension in LicenseOnly mode, checks local SQL plus Azure
inventory, then removes the minted credential and verifies the original key IDs.
Cleanup runs after build failures too. It stops on a failed step; do not blindly
rerun the whole build against an existing guest.
The individual New/Wait/Connect/Engine/Enable/Test scripts support targeted
continuation through `Invoke-NestedSqlDemoStep.ps1`.

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
compute, starts the guest and waits for Arc; it does not reconnect/reinstall SQL.

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
