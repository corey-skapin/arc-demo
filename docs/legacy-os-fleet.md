# Legacy OS fleet configuration

`bicep/main.bicep` now drives the simulated on-prem estate from the
`onPremFleet` array instead of fixed Windows/Linux counts. Each `deploymentMode:
'azure-vm'` entry becomes a backing Azure VM and is Arc-onboarded. Entries with
`deploymentMode: 'represent-not-run'` are documentation/demo placeholders for
tiers that cannot be reliably sourced as Azure Marketplace images.

## Fleet schema

| Field | Purpose |
|---|---|
| `name` | VM and Arc machine name. |
| `role` | Demo role, for example `sql`, `app`, or `legacy`. |
| `osType` | `Windows` or `Linux`. |
| `osTier` | Human-readable OS tier such as `WS2012R2`, `WS2016`, `WS2019`, `WS2022`, or `Ubuntu22.04`. |
| `imagePublisher`, `imageOffer`, `imageSku`, `imageVersion` | Azure Marketplace image reference used by the VM module. |
| `deploymentMode` | `azure-vm` to deploy/onboard, or `represent-not-run` for old tiers that are discussed but not deployed. |
| `monitorTier` | Demo classification: `full-monitor`, `arc-control-plane-only`, `full-monitor-no-vmi-map`, or `represent-not-run`. |
| `supportsAzureMonitor` | Enables AMA install and the core DCR association. Set `false` for pre-2016 Windows tiers. |
| `supportsVmInsights` | Enables VM Insights DCR + Windows Dependency Agent. Set `true` only for supported Windows tiers. |
| `supportsChangeTracking` | Enables Change Tracking DCR + extension. Set `false` for legacy Windows tiers that cannot run AMA. |
| `supportsSql` | Marks SQL-capable hosts. SQL Server install, Arc SQL extension, and BPA still run only when the optional advanced SQL path is explicitly enabled with `-InstallSql` or `workloads.installSql=true`. |
| `esuEligible` | Surfaces the ESU discussion in Arc machine tags; it does not buy or configure ESU. |

The deploy script also tags every Arc machine with `osTier`, `monitorTier`,
`esuEligible`, `inventory=arc`, `updateManager=assessment`, `defender=plan2`,
and `machineConfig=enabled` so the Arc control-plane story is visible for all
Arc-onboarded machines, including legacy entries.

## Monitoring gates

- **WS2016 / WS2019 / WS2022**: set `supportsAzureMonitor`,
  `supportsVmInsights`, and `supportsChangeTracking` to `true` for the full
  Azure Monitor, VM Insights, and Change Tracking path.
- **WS2012R2 / older Windows**: set all Monitor booleans to `false`. These
  machines are Arc-control-plane-only: inventory/resource graph, Update Manager
  assessment where supported, Defender for Servers, Machine Configuration, tags,
  and ESU-eligibility surfacing.
- **Linux demo hosts**: keep AMA and Change Tracking enabled, but leave
  `supportsVmInsights=false` unless you have validated Dependency Agent support
  for the chosen distro/kernel.

## Image approach for truly old OS tiers

Azure Marketplace availability varies by region, subscription, and retirement
state. For WS2012R2, try an explicit Marketplace SKU such as
`MicrosoftWindowsServer:WindowsServer:2012-R2-Datacenter:latest` only after
validating it in the target region:

```powershell
az vm image list --location australiaeast `
  --subscription <SUBSCRIPTION_ID> `
  --publisher MicrosoftWindowsServer `
  --offer WindowsServer `
  --sku 2012-R2-Datacenter `
  --all -o table
```

If the image is unavailable, use one of these demo-safe patterns:

1. **Oldest feasible Marketplace image**: deploy WS2016 as the oldest runnable
   VM tier and explain that WS2012R2 follows the same Arc-control-plane-only
   path without Monitor payloads.
2. **Nested Hyper-V**: deploy a supported Azure VM host and run the truly old OS
   inside nested virtualization for a lab-only deep demo.
3. **Represent-not-run**: include a `deploymentMode: 'represent-not-run'` entry
   in the fleet config and cover it in the narrative without deploying it.

`bicep/params/mixed-legacy-fleet.bicepparam` contains a validation fixture with
WS2012R2, WS2016, WS2019, WS2022, and a represented WS2008R2 placeholder.
Its IDs/mailbox are synthetic, and its password is read from the process-local
`ARC_DEMO_ADMIN_PASSWORD` environment variable, not stored in the fixture.
See [Bicep parameter-file environment inputs](https://learn.microsoft.com/azure/azure-resource-manager/bicep/parameter-files#define-parameters-file).
This file is a validation reference, not an existing estate's retained input.
Do not print or commit compiled parameter JSON containing the supplied password.
