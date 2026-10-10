# arc-demo module map

Line references are from `main` at `51b1f43` when this map was written.
This is a documentation-only inventory for T01; it does not change runtime behavior.

## Repo purpose and high-level architecture

`arc-demo` is a scripted Azure Arc + Azure Monitor demo lab. It creates Azure VMs
that simulate on-prem servers, Arc-onboards them with `MSFT_ARC_TEST=true`, and
then shows a centrally managed Arc/Monitor operations plane.

The deployment intentionally splits resources into two groups:

- `rg-<prefix>` / default `rg-arc-demo`: customer-facing Arc and observability
  resources: Arc server records, Arc SQL records, Log Analytics workspace, DCRs,
  workbooks, alert rule, and action group.
- `rg-<prefix>-infra` / default `rg-arc-demo-infra`: hidden backing Azure lab
  infrastructure: VNet, NSG, Key Vault, simulated on-prem Azure VMs, VM NICs,
  auto-shutdown schedules, and active-state NAT Gateway/public IP.

Current fleet shape is config-driven by the `onPremFleet` array in
`bicep/main.bicep`: Windows Server image tiers, Linux image tiers, role, SQL
eligibility, Monitor support, and ESU surfacing are data, not name/count logic.
`scripts/Deploy-ArcDemo.ps1` then performs all imperative lifecycle work after
Bicep completes and gates Monitor payloads from the fleet metadata.

## Bicep entry point and modules

- `bicep/main.bicep`
  - Subscription-scope template (`targetScope = 'subscription'`) at lines 1-6.
  - Creates the two resource groups at lines 75-85.
  - Wires modules in this order:
    - `workspaceMod` at lines 89-97.
    - `dcrsMod` at lines 99-102 (deterministic DCR ID outputs only; DCR resources are created post-Bicep by the deploy script).
    - `alertsMod` at lines 110-120.
    - `networkMod` at lines 124-133.
    - `kvMod` at lines 135-145.
    - `vmMods` loop at lines 168-186.
    - subscription modules `defenderMod`, `policyMod`, `budgetMod` at lines
      190-212.
  - Outputs RG names, workspace IDs, Key Vault name, subnet ID, VM names, DCR IDs,
    and action group ID at lines 216-226.

- `bicep/modules/workspace.bicep`
  - Deploys `Microsoft.OperationalInsights/workspaces` using `PerGB2018`,
    30-day default retention, and resource-context log access at lines 17-28.
  - Deploys OMS solutions `VMInsights(<workspace>)` and
    `ChangeTracking(<workspace>)` at lines 30-58 so the required tables exist.
  - Outputs workspace resource ID, workspace name, and customer ID at lines 60-62.

- `bicep/modules/dcrs.bicep`
  - Outputs deterministic IDs for `dcr-arc-demo`, `dcr-vminsights`, and
    `dcr-changetracking` without creating the resources in the initial Bicep
    deployment.
  - `Deploy-ArcDemo.ps1` creates/updates all three DCRs after the workspace
    solutions have provisioned their required Log Analytics tables, which avoids
    first-run table-readiness failures on clean prefixes.

- `bicep/modules/alerts.bicep`
  - Deploys email Action Group `ag-<prefix>` at lines 18-33.
  - Deploys scheduled query rule `alert-<prefix>-host-missing-heartbeat` at
    lines 35-66. It runs every 5 minutes over a 15-minute window and fires when
    a host has no `Heartbeat` for more than 10 minutes.
  - Outputs action group and alert rule IDs at lines 68-69.

- `bicep/modules/network.bicep`
  - Deploys empty NSG `nsg-<prefix>` at lines 30-37.
  - Deploys VNet `vnet-<prefix>` and subnet `snet-vms` at lines 39-60.
  - Preserves an existing NAT Gateway attachment if `existingNatGatewayId` is
    passed, at lines 50-56. NAT creation/deletion is intentionally done by
    lifecycle scripts so hibernation can remove that cost.

- `bicep/modules/keyvault.bicep`
  - Deploys a standard RBAC-enabled Key Vault for the shared VM admin password at
    lines 18-30.
  - Grants Key Vault Administrator to the deploying user at lines 32-43.

- `bicep/modules/vm.bicep`
  - Deploys one NIC at lines 45-60.
  - Deploys one system-assigned-identity VM at lines 62-95 using caller-supplied
    image publisher/offer/SKU and `osType`.
  - Deploys a DevTest Labs auto-shutdown schedule for the VM at lines 97-109.

- `bicep/modules/defender.bicep`
  - Enables Defender for Servers Plan 2 at subscription scope using
    `Microsoft.Security/pricings/VirtualMachines` at lines 5-11.

- `bicep/modules/policy.bicep`
  - Assigns Microsoft Cloud Security Benchmark (`mcsb-<prefix>`) at lines 14-23.
  - Assigns NIST SP 800-53 Rev. 5 (`nist-<prefix>`) at lines 25-34.

- `bicep/modules/budget.bicep`
  - Deploys subscription budget `budget-<prefix>` filtered to the Arc and infra
    resource groups at lines 26-42.
  - Sends email notifications at 50/80/100% actual and 100% forecast at lines
    43-60.

## Deployment parameters and current defaults

### `bicep/main.bicep` parameters

- `location` = `australiaeast` (`main.bicep:8-9`).
- `arcResourceGroup` = `rg-arc-demo` (`main.bicep:11-12`).
- `infraResourceGroup` = `rg-arc-demo-infra` (`main.bicep:14-15`).
- `tags` = `{ owner: 'demo', purpose: 'arc-demo', costcenter: 'demo', env: 'demo' }`
  (`main.bicep:17-23`).
- `tenantId` required (`main.bicep:25-26`).
- `deployerPrincipalId` required (`main.bicep:28-29`).
- `keyVaultName` required (`main.bicep:31-32`).
- `adminUsername` = `azureuser` (`main.bicep:34-35`).
- `adminPassword` secure required (`main.bicep:37-39`).
- `onPremFleet` = default mixed WS2016/WS2019/WS2022 + Ubuntu fleet; each
  entry carries role, OS image, Monitor support, SQL support, deployment mode,
  and ESU eligibility metadata.
- `vmSize` = `Standard_B2as_v2` (`main.bicep:51-52`).
- `autoShutdownTime` = `1900` (`main.bicep:54-55`).
- `autoShutdownTimezone` = `Cen. Australia Standard Time` (`main.bicep:57-58`).
- `adminEmail` required (`main.bicep:60-61`).
- `budgetAmount` = `200` (`main.bicep:63-64`).
- `namePrefix` = `arc-demo` (`main.bicep:66-67`).
- `existingNatGatewayId` = empty string (`main.bicep:69-70`).
- `existingBudgetStartDate` = `utcNow('yyyy-MM-01')` (`main.bicep:72-73`).

There are no committed `.bicepparam` or ARM parameter files. The deploy script
creates an ephemeral ARM deployment parameter JSON file at
`Deploy-ArcDemo.ps1:104` and fills it at lines 127-149.

### Module-internal parameter defaults

- `workspace.bicep`: `workspaceName = law-arc-demo`, `retentionInDays = 30`
  (`workspace.bicep:9-15`).
- `dcrs.bicep`: no defaults besides caller-supplied workspace references.
- `alerts.bicep`: `namePrefix = arc-demo` (`alerts.bicep:15-16`).
- `network.bicep`: `namePrefix = arc-demo`, `subnetName = snet-vms`,
  `addressPrefix = 10.50.0.0/16`, `subnetPrefix = 10.50.1.0/24`,
  `existingNatGatewayId = ''` (`network.bicep:15-28`).
- `keyvault.bicep`: no default vault, tenant, or principal values.
- `vm.bicep`: no default VM/image/credential values; these are supplied by
  `main.bicep` from the generated fleet objects.
- `policy.bicep`: `namePrefix = arc-demo` (`policy.bicep:8-9`).
- `budget.bicep`: `namePrefix = arc-demo`, `startDate = utcNow('yyyy-MM-01')`,
  `endDate = two years from current UTC month` (`budget.bicep:17-24`).

### PowerShell script parameters

- `scripts/Deploy-ArcDemo.ps1` (`Deploy-ArcDemo.ps1:73-86`):
  - Required: `SubscriptionId`, `TenantId`, `AdminEmail`.
  - Defaults: `Location = australiaeast`, `NamePrefix = arc-demo`,
    `OnPremFleetPath = ''` (use Bicep's default fleet), deprecated
    compatibility counts `WindowsVmCount = 5`, `LinuxVmCount = 3`,
    `VmSize = Standard_B2as_v2`, `AutoShutdownTime = 1900`,
    `AutoShutdownTimezone = Cen. Australia Standard Time`,
    `BudgetAmount = 200`, `SkipSqlInstall = $false`.
  - Inherits `-WhatIf` from `CmdletBinding(SupportsShouldProcess)` and uses
    `$WhatIfPreference` at lines 161-167 to run `az deployment sub what-if` and
    stop before changing resources.

- `scripts/Test-Prerequisites.ps1` (`Test-Prerequisites.ps1:19-27`):
  - Required: `SubscriptionId`, `TenantId`.

- `scripts/Activate-ArcDemo.ps1` (`Activate-ArcDemo.ps1:25-29`):
  - `NamePrefix = arc-demo`, `Location = australiaeast`,
    `SkipValidate = $false`.

- `scripts/Hibernate-ArcDemo.ps1` (`Hibernate-ArcDemo.ps1:20-23`):
  - `NamePrefix = arc-demo`; supports `-WhatIf`.

- `scripts/Remove-ArcDemo.ps1` (`Remove-ArcDemo.ps1:28-32`):
  - `NamePrefix = arc-demo`, `KeepDefender = $false`; supports `-WhatIf`.

- `scripts/lib/Common.psm1` helper defaults:
  - `Wait-Until`: timeout 600 seconds, interval 15 seconds, message `Waiting`
    (`Common.psm1:175-199`).
  - `New-StrongPassword`: length 24 (`Common.psm1:205-210`).
  - `New-KeyVaultName`: prefix `kv-arcdemo` (`Common.psm1:212-217`).

## PowerShell lifecycle scripts and phases

### Prerequisite tests

- `scripts/Test-Prerequisites.ps1` is a thin wrapper that imports
  `Common.psm1` and calls `Test-Prerequisites` (`Test-Prerequisites.ps1:24-29`).
- `Test-Prerequisites` in `Common.psm1:49-132` checks:
  - PowerShell 7.4+ (`Common.psm1:64-68`).
  - Azure CLI 2.60+ (`Common.psm1:70-79`).
  - Bicep CLI availability (`Common.psm1:81-87`).
  - Active subscription and tenant, switching subscription if needed
    (`Common.psm1:89-100`).
  - Owner/User Access Administrator signal (`Common.psm1:102-113`).
  - Required resource provider registration trigger (`Common.psm1:115-130`).

### Deploy lifecycle

`Deploy-ArcDemo.ps1` advertises its full phase list at lines 1-24 and implements:

1. Pre-flight checks through `Test-Prerequisites` (`Deploy-ArcDemo.ps1:92-93`).
2. Generate admin password, build ephemeral parameter file, preserve existing NAT
   Gateway/budget start, deploy `bicep/main.bicep`, and capture outputs
   (`Deploy-ArcDemo.ps1:100-188`).
3. Create Core, VM Insights, and Change Tracking DCRs after workspace/table
   readiness.
4. Create/attach NAT Gateway and public IP (`Deploy-ArcDemo.ps1:256-280`).
5. Create or reset Arc onboarding service principal
   (`Deploy-ArcDemo.ps1:282-296`).
6. Generate onboarding scripts and Arc-onboard backing VMs in parallel
   (`Deploy-ArcDemo.ps1:298-365`).
7. Install AMA on Windows via Arc extension and Linux via Azure VM extension,
   then associate core/VMI/CT DCRs with Arc HybridCompute resource IDs
   (`Deploy-ArcDemo.ps1:367-407`).
8. Install Windows Dependency Agent for VM Insights Map
   (`Deploy-ArcDemo.ps1:409-423`).
9. Install Change Tracking extensions for both OS families
   (`Deploy-ArcDemo.ps1:425-448`).
10. Optionally install SQL Server 2022 Developer on `win-sql-*` hosts
    (`Deploy-ArcDemo.ps1:450-491`).
11. Arc-enable SQL with `WindowsAgent.SqlServer`, BPA, and paid licensing flag
    (`Deploy-ArcDemo.ps1:493-501`).
12. Publish the custom workbook and five vendored Nic Seilaz workbooks
    (`Deploy-ArcDemo.ps1:504-563`).
13. Validate recent Heartbeats and print portal URLs
    (`Deploy-ArcDemo.ps1:565-594`).

### Activate lifecycle

`Activate-ArcDemo.ps1` wakes a hibernated environment:

1. Create/reuse NAT public IP and NAT Gateway, attach to subnet
   (`Activate-ArcDemo.ps1:43-60`).
2. Start all VMs in parallel and wait for running state
   (`Activate-ArcDemo.ps1:62-70`).
3. Restart Arc and AMA agents via VM run-command (`Activate-ArcDemo.ps1:72-92`).
4. Unless `-SkipValidate`, wait for Arc Connected and recent Heartbeat from all
   hosts (`Activate-ArcDemo.ps1:99-121`).

### Hibernate lifecycle

`Hibernate-ArcDemo.ps1` parks the demo cheaply:

1. Deallocate all VMs in parallel and wait until none are running
   (`Hibernate-ArcDemo.ps1:37-50`).
2. Detach/delete NAT Gateway, then delete NAT public IP
   (`Hibernate-ArcDemo.ps1:52-68`).
3. Leaves workspace, DCRs, workbooks, alerts, Arc records, and OS disks intact
   (`Hibernate-ArcDemo.ps1:5-9`).

### Remove lifecycle

`Remove-ArcDemo.ps1` tears down the lab:

1. Delete MCSB/NIST policy assignments (`Remove-ArcDemo.ps1:46-53`).
2. Delete cost budget via REST (`Remove-ArcDemo.ps1:55-60`).
3. Delete Arc onboarding SPN (`Remove-ArcDemo.ps1:63-68`).
4. Submit both resource groups for deletion (`Remove-ArcDemo.ps1:70-80`).
5. Unless `-KeepDefender`, revert Defender for Servers to Free
   (`Remove-ArcDemo.ps1:82-88`).

### Shared helpers

`Common.psm1` contains logging helpers (`Common.psm1:10-45`), prereq checks
(`Common.psm1:47-134`), Azure REST/token helpers (`Common.psm1:136-169`),
polling (`Common.psm1:173-199`), and name/password helpers
(`Common.psm1:203-217`).

## Existing monitoring, security, policy, and workbook behavior

- Log Analytics:
  - Workspace `law-<prefix>` is deployed by `workspace.bicep` with 30-day
    retention (`workspace.bicep:17-28`).
  - Workspace solutions VM Insights and Change Tracking are deployed by Bicep
    (`workspace.bicep:30-58`).

- DCRs and agents:
  - Core DCR collects perf counters, Windows events, and Linux syslog
    (created post-Bicep by `Deploy-ArcDemo.ps1`).
  - VM Insights DCR collects `InsightsMetrics` and `ServiceMap`
    (created post-Bicep by `Deploy-ArcDemo.ps1`).
  - Change Tracking DCR is created by the same post-Bicep REST phase after
    tables are ready.
  - DCR associations are deliberately created against Arc resource IDs for every
    current host (`Deploy-ArcDemo.ps1:393-407`).
  - AMA is Windows-via-Arc and Linux-via-Azure-VM-extension because the Ubuntu
    Arc extension stack is called out as broken in `AGENTS.md:41-43` and the
    deploy script implements that at `Deploy-ArcDemo.ps1:370-387`.
  - Dependency Agent currently installs on Windows only (`Deploy-ArcDemo.ps1:409-423`).
  - Change Tracking extension installs on Windows and Linux (`Deploy-ArcDemo.ps1:425-448`).

- Alerts:
  - Email Action Group only (`alerts.bicep:18-33`).
  - Missing-heartbeat scheduled query rule is Sev-2, enabled, 5-minute evaluation,
    15-minute window, `autoMitigate = true`, query at `alerts.bicep:50`
    (`alerts.bicep:35-66`).
  - Runbook notes the future ITSM/webhook one-liner at `docs/runbook.md:520-539`.

- Defender:
  - Defender for Servers Plan 2 is enabled at subscription scope by
    `defender.bicep:5-11`.
  - Arc SQL host extension is installed after SQL setup and enables SQL
    management/BPA (`Deploy-ArcDemo.ps1:493-501`).

- Policy:
  - MCSB and NIST 800-53 Rev. 5 are subscription-scope assignments with
    system-assigned identities (`policy.bicep:11-34`).
  - Compliance scorecards are expected to take around 12 hours to populate
    (`Deploy-ArcDemo.ps1:590-592`, `docs/troubleshooting.md:132-142`).

- Workbooks:
  - Custom one-pager `workbooks/arc-demo-overview.workbook.json` contains tiles
    for Heartbeat connectivity, host count over time, CPU, Change Tracking,
    software inventory, Resource Graph tagging hygiene, Windows critical/error
    events, and Linux syslog errors.
  - Five vendored Nic Seilaz workbooks are published in Phase 11 from
    `Deploy-ArcDemo.ps1:552-563`; descriptions are in
    `workbooks/nseilaz/README.md:8-20`.
  - Workbook publishing is idempotent by `workbookTag`
    (`Deploy-ArcDemo.ps1:520-545`).

## Exact insertion points for T02 workload-toggle framework

Target behavior: keep today's result when `deployArcOnPrem = true` and the other
new workload toggles are false; do not add SRE dependencies.

1. Add Bicep boolean parameters in `bicep/main.bicep` immediately after
   `namePrefix` at lines 66-67 and before the operational pass-through
   parameters at lines 69-73:
   - `deployArcOnPrem bool = true`
   - `deployAzureVMs bool = false`
   - `deployContainerApps bool = false`
   - `deployAks bool = false`

2. Gate the current on-prem-simulated Arc workload in `bicep/main.bicep`:
   - VM fleet generation currently starts at lines 147-166.
   - VM module loop is at lines 168-186.
   - Condition the VM module loop, Arc workload outputs, and any new Arc workload
     metadata on `deployArcOnPrem`.
   - Keep shared foundation modules (`workspaceMod`, `dcrsMod`, `alertsMod`,
     `defenderMod`, `policyMod`, `budgetMod`) outside the gate unless a later
     task chooses otherwise; they are the common observability plane.

3. Add placeholder module hooks after the current VM module loop
   (`main.bicep:168-186`) and before subscription-scoped pieces
   (`main.bicep:188-212`):
   - `modules/azure-vms.bicep` behind `if (deployAzureVMs)` for T04.
   - `modules/container-apps.bicep` behind `if (deployContainerApps)` for T05.
   - `modules/aks.bicep` behind `if (deployAks)` for T06.
   These can start as compile-only stubs returning empty arrays/IDs until the
   later workload tasks fill them.

4. Extend `scripts/Deploy-ArcDemo.ps1` parameters at lines 73-86 with matching
   switches/booleans and defaults. Keep them explicit; do not infer from counts.

5. Add the new parameter values to the generated parameter JSON at
   `Deploy-ArcDemo.ps1:127-149`.

6. Guard imperative Arc-server phases that assume `$vmNames` represents the whole
   deployment:
   - Arc onboarding files and jobs: `Deploy-ArcDemo.ps1:298-365`.
   - AMA and DCR associations: `Deploy-ArcDemo.ps1:367-407`.
   - Dependency Agent: `Deploy-ArcDemo.ps1:409-423`.
   - Change Tracking extension: `Deploy-ArcDemo.ps1:425-448`.
   - SQL install / Arc SQL extension: `Deploy-ArcDemo.ps1:450-501`.
   - Heartbeat validation count: `Deploy-ArcDemo.ps1:565-581`.
   If `deployArcOnPrem = false`, these phases should skip cleanly rather than
   waiting on zero or missing Arc machines.

7. Update lifecycle scripts to work from discovered resources for all workload
   types later, but for T02 at minimum document/keep that `Activate-ArcDemo.ps1`
   and `Hibernate-ArcDemo.ps1` currently operate only on VMs in
   `rg-<prefix>-infra` (`Activate-ArcDemo.ps1:62-92`,
   `Hibernate-ArcDemo.ps1:37-68`).

8. Update README customisation surface at `README.md:85-100` in T02/T07 so the
   toggles are discoverable. Do not update it in T01 beyond this map.

## Exact insertion points for T03 config-driven legacy-OS fleet

Target behavior: fleet is data-driven; 2016+ machines receive AMA/VM Insights/
Change Tracking; 2008/2012-era machines are Arc-control-plane-only and must not
receive unsupported Azure Monitor Agent payloads.

1. Replace count-based VM generation in `bicep/main.bicep:147-166` with a fleet
   array/object parameter. Include at least: `name`, `role`, `osType`, image
   publisher/offer/SKU/version, `monitorTier` or `supportsAzureMonitor`, and
   optional `sqlRole`/`tags` fields. Defaults should reproduce the current 5×
   Windows Server 2022 + 3× Ubuntu 22.04 fleet.

2. Keep `bicep/modules/vm.bicep` as the VM primitive. It already accepts
   caller-supplied image publisher/offer/SKU and OS type at lines 26-37 and
   applies OS-specific config at lines 69-75. T03 likely needs only small
   extensions here for image `version`, Marketplace `plan`, or generation-specific
   options if older images require them.

3. Change `main.bicep` outputs at lines 216-226 to include machine metadata, not
   just `vmNames`, so the deploy script can tell which hosts support Monitor,
   which are legacy, and which should run SQL.

4. Replace deploy-script name-pattern classification at
   `Deploy-ArcDemo.ps1:180-188`:
   - Current `$winVms`, `$lnxVms`, `$sqlVms` are derived from names.
   - T03 should derive these from fleet metadata, plus new groups such as
     `$monitorVms`, `$arcOnlyVms`, `$monitorWindowsVms`, and `$monitorLinuxVms`.

5. Keep Arc onboarding for every VM (`Deploy-ArcDemo.ps1:329-365`), but validate
   the onboarding commands for each legacy OS. Windows onboarding uses the generic
   MSI path at lines 301-311; Linux onboarding is hardcoded to Ubuntu 22.04 apt
   repo at lines 312-323 and is not suitable as a generic legacy Linux path.

6. Restrict Monitor payloads to supported OS tiers:
   - AMA install loops at `Deploy-ArcDemo.ps1:370-387`.
   - DCR associations at `Deploy-ArcDemo.ps1:393-407`.
   - Dependency Agent at `Deploy-ArcDemo.ps1:409-423`.
   - Change Tracking extension at `Deploy-ArcDemo.ps1:425-448`.
   Legacy 2008/2012 entries must be excluded from these loops.

7. Gate SQL install and Arc SQL extension by fleet role/capability instead of the
   `win-sql-*` naming convention (`Deploy-ArcDemo.ps1:450-501`).

8. Update docs and operator surfaces after implementation:
   - README parameter/customisation table at `README.md:85-100`.
   - Architecture topology docs at `docs/architecture.md:12-35` and data-flow
     assumptions at `docs/architecture.md:85-95`.
   - Runsheet beats for Arc control-plane-only legacy hosts at
     `docs/runsheet.md:38-79`.

## Risks and unknowns

- Legacy OS support split:
  - Plan.md records a hard constraint that AMA supports Windows Server 2016+ only.
    T03 must ensure 2008/2012 hosts do not receive AMA, VM Insights, or Change
    Tracking DCR/extension payloads.
  - Arc Connected Machine Agent, Update Manager, Defender, Machine Configuration,
    and ESU capability/support need fresh validation against current Microsoft
    Learn before making claims for each legacy OS tier.

- Legacy image availability:
  - Current Bicep uses Windows Server 2022 Azure Edition and Ubuntu 22.04 images
    only (`main.bicep:147-164`). WS2008/2012 Marketplace images may be absent,
    hidden, or require Marketplace plan terms. T03 may need oldest-feasible images,
    nested Hyper-V, or represent-not-run records as already noted in plan.md.

- Linux assumptions:
  - Linux onboarding is Ubuntu 22.04-specific (`Deploy-ArcDemo.ps1:312-323`).
    Any non-Jammy Linux tier needs a distro-aware onboarding path.
  - Dependency Agent Linux is already skipped because Ubuntu 22.04 kernels are
    unsupported (`AGENTS.md:41-43`, `Deploy-ArcDemo.ps1:409-423`).

- New-subscription first run:
  - Requires Owner/UAA-like permissions, Bicep CLI, Azure CLI, provider
    registration, SPN creation permission, policy assignment permission, Key Vault
    RBAC propagation, and regional capacity for the chosen VM SKU.
  - `Test-Prerequisites` registers providers but does not wait for completion
    (`Common.psm1:115-130`), so a pristine subscription may need reruns or waits.
  - Budget start dates cannot be changed after creation; the deploy script already
    preserves them on rerun (`Deploy-ArcDemo.ps1:116-125`).
  - B-series capacity in AU regions is known to be unreliable
    (`AGENTS.md:45-46`, `docs/troubleshooting.md:6-30`).

- Hibernation/activation scope:
  - Current lifecycle scripts assume VM-backed workloads in the infra RG and know
    nothing about future Container Apps or AKS. T02 can add toggles without solving
    this, but T05/T06/T07 must clarify active/hibernated cost controls per workload.

- Alerting scope:
  - Current alert is missing-host heartbeat only. Future Container Apps and AKS
    workloads will need their own metric/log alerts routed to the same or extended
    Action Group.