# Nested SQL demo: build, park, wake, remove

The primary path is a **scratch Windows Server 2022 guest with SQL Server 2022
Developer and Arc**. The repo-only rehearsal took **45m44s**, parked in **4m03s**,
woke in **2m41s**, and parked again in **3m02s**. Wake preserved the guest and Arc
identities, passed a real SQL query and extension/login checks, and uploaded fresh
inventory with four Online system databases. These are observed timings, not SLAs.

This is an Azure-hosted nested **demo**, not a production support claim. The
from-zero proof rebuilt the guest, **not** the prepared Azure parent, media,
Hyper-V network or private onboarding infrastructure. Use approved Windows/SQL
media and terms; Developer/Evaluation editions are not production licences.
The normal fleet's `MSFT_ARC_TEST=true` simulation is a separate path.

## Prepare once

Keep the existing Windows Hyper-V parent, switch/NAT, mounted Windows Server 2022
and SQL Server 2022 media, and private Arc onboarding secret. Do not rotate
credentials, change Defender policy/pricing, or rebuild a retained parent to wake
the guest. The parent needs sufficient memory, nested-virtualization support and
space for the guest's 64-GiB OS and 32-GiB data disks.

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

Put the build's nonsecret arguments in `.local\nested-sql-build.json`: explicit
`SubscriptionId`, `TenantId`, retained `ParentVmId`, `Location`, parent-side
`WindowsIsoPath` and `SqlIsoPath`, `SwitchName`, `GuestAddress`, `Gateway`,
`DnsServer`, `OnboardingApplicationId`, exact `SecretVersionUri`, and
`VaultPrivateAddress`. All IDs, addresses, media paths and results stay outside
git. `Get-Help .\scripts\New-NestedSqlDemo.ps1 -Full` lists these inputs.

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

Preview is not creation. The real invocation creates only a new named guest/root,
waits for unattended setup, connects Arc, installs SQL, enables the SQL extension
in LicenseOnly mode, and checks local SQL plus Azure inventory. It stops on a
failed step; do not blindly rerun the whole build against an existing guest.
The individual New/Wait/Connect/Engine/Enable/Test scripts support targeted
continuation through `Invoke-NestedSqlDemoStep.ps1`.

| Successful scratch-build step | Observed time |
|---|---:|
| Create/image/first boot | 11m51s |
| Wait for unattended setup | 5m07s |
| Arc connect/private vault | 7m16s |
| SQL install/version query | 7m26s |
| SYSTEM permission check/SQL-only unblock | 2m59s |
| Arc SQL extension | 5m31s |
| Azure SQL/database inventory | 1m46s |
| Local Windows/Arc/SQL/extension check | 2m34s |
| Total including orchestration | 45m44s |

Times exclude earlier failed attempts, debugging and removal. Scratch fixes were
cold DNS readiness, actual SQL bootstrap paths, parsing the agent block list,
and treating the first extension GET 404 as bounded creation lag.

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
the retained parent; the consolidated whole-estate wiring has mocked coverage,
not a newly executed whole-estate lifecycle proof.

The merged skin/Common **pair-only** path was also exercised live on
31 October 2026: wake, including Arc Connected, took 311.3 seconds; graceful
guest `Off` followed by parent-only deallocation took 143.5 seconds. The same
guest GUID, two disk paths and Arc VM ID were verified, SQL queried successfully,
and all four system databases remained Online with a fresh inventory upload.
The extension ARM state temporarily returned `Creating` before `Succeeded`;
bounded read-only observation settled it without reinstall or repair. No
fleet-wide lifecycle operation was run, and the pair was left parked.

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
|---|---|---|
| Scratch, primary | Prepared parent/media/network/vault; corrected Server 2022 BCDBoot, DNS, bootstrap/block-list parsing and extension creation lag | Repo-only guest build 45m44s; park 4m03s; wake 2m41s; repark 3m02s; retained identities and fresh SQL inventory |
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
