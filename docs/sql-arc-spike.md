# SQL Server / Arc SQL spike

## Decision

Do **not** include Arc-enabled SQL Server as a default or customer-facing validated
beat in this Azure-only lab.

The SQL story is important, but there are two separate cases:

| Case | Status | Demo stance |
|---|---|---|
| Real non-Azure server, for example customer Hyper-V/VMware/on-prem VM connected with Azure Arc | Supported by Microsoft docs when prerequisites are met | Good customer conversation and future lab path |
| This repo's simulated on-prem hosts, which are Azure VMs Arc-enabled with `MSFT_ARC_TEST=true` | Not a supportable Arc SQL validation target because SQL Server in Azure Virtual Machines is listed as unsupported for SQL Server enabled by Azure Arc | Do not sell as validated; keep skipped by default |

The current script previously attempted to install SQL Server 2022 Developer on
the Azure-VM-backed Arc hosts and then add `WindowsAgent.SqlServer`. That failed
in live testing with a setup hang and is not the right shareable path because the
underlying lab host type is still an Azure VM.

## What the official docs say

The SQL Server enabled by Azure Arc prerequisites page states:

- SQL Server enabled by Azure Arc supports SQL Server 2014 and later, 64-bit only.
- Supported Windows OS starts at Windows Server 2016.
- `Microsoft.AzureArcData` and `Microsoft.HybridCompute` must be registered.
- The installer needs local administrator permissions and Azure permissions to
  deploy Connected Machine extensions.
- The Azure extension for SQL Server is `WindowsAgent.SqlServer` on Windows and
  can be installed through `az connectedmachine extension create`.
- The extension discovers installed SQL Server instances and creates `SQL Server -
  Azure Arc` resources.
- Unsupported configurations include **SQL Server in Azure Virtual Machines**,
  SQL Server in containers, SQL Server 2012 and older, and Windows Server versions
  earlier than Windows Server 2016.

This means the DTF/customer scenario remains valid because DTF-style Hyper-V or
VMware-hosted SQL servers are non-Azure machines. The all-Azure demo simulation is
the part that should not claim supported Arc SQL validation.

## Current repo implementation

`scripts\Deploy-ArcDemo.ps1` has an optional `-InstallSql` path:

1. Downloads SQL Server installer bootstrapper from `go.microsoft.com/fwlink/?linkid=2215158`.
2. Uses `SSEI.exe /ACTION=Download /MEDIAPATH=C:\SQL2022 /MEDIATYPE=ISO /QUIET`.
3. Mounts the ISO and runs `setup.exe` for the default `MSSQLSERVER` instance.
4. Installs the `WindowsAgent.SqlServer` Connected Machine extension with:
   - `SqlManagement.IsEnabled=true`
   - `LicenseType=Paid`
   - `AzureBestPracticesAssessment.IsEnabled=true`

That path is skipped by default. It is not currently a reliable or supportable
shareable branch for this Azure-only lab.

Preserved logs under `logs\add-sql2016-*.log` do not contain a clean SQL setup
failure. They mostly show earlier deployment idempotency failures such as
`osDisk.name` / managed disk SKU immutability and budget start-date updates. The
more recent live run symptom was a long-running SQL setup phase that did not
complete in the demo window.

## Supported ways to tell the SQL story

### Option A - customer-realistic SQL branch

Use this when the customer has, or the SE can provide, a real non-Azure Windows
Server 2016+ machine with SQL Server 2014+ installed.

1. Connect the machine to Azure Arc.
2. Verify outbound access to:
   - `aka.ms`
   - `*.web.core.windows.net`
   - `*.<region>.arcdataservices.com` on TCP 443
3. Register providers:
   ```powershell
   az provider register --namespace Microsoft.HybridCompute
   az provider register --namespace Microsoft.AzureArcData
   ```
4. Install the SQL extension:
   ```powershell
   az connectedmachine extension create `
     --machine-name <arc-machine-name> `
     --resource-group <arc-resource-group> `
     --location <region> `
     --name WindowsAgent.SqlServer `
     --publisher Microsoft.AzureData `
     --type WindowsAgent.SqlServer `
     --settings '{"SqlManagement":{"IsEnabled":true}, "LicenseType":"Paid", "AzureBestPracticesAssessment":{"IsEnabled":true}}'
   ```
5. Validate in **Azure Arc > SQL Server**.
6. Wait 30-60 minutes before expecting Best Practices Assessment results.

This is the right path for a customer-owned Hyper-V/VMware SQL Server estate.

### Option B - keep this demo Azure-only and skip SQL

Use this for the shareable SE demo kit.

- Keep `-InstallSql` off.
- Treat `win-sql-01` / `win-sql-02` as SQL-capable Windows hosts in the narrative,
  not as Arc-enabled SQL Server instances.
- Use the Arc inventory, Defender, Update Manager, Machine Configuration, Monitor,
  and alerting beats.
- Mention that Arc-enabled SQL Server requires a real non-Azure SQL host for a
  supported lab validation.

### Option C - future separate SQL lab

Create a small separate SQL-specific lab that uses a non-Azure VM target:

- Hyper-V/VMware local VM, AVS with the supported AVS Arc deployment path, or
  another non-Azure cloud/host.
- Pre-install SQL Server from a known ISO or image controlled by the operator.
- Connect the host to Azure Arc.
- Install `WindowsAgent.SqlServer`.
- Validate inventory, Defender for SQL, BPA, and any SRE diagnostic hooks.

This should be a separate repo/task, not bolted onto the default Azure-only Arc
demo.

## Customer-safe wording

Use:

> Arc-enabled SQL Server is a strong follow-on for real on-prem SQL estates. This
> Azure-only lab keeps SQL disabled because the Arc SQL product does not support
> SQL Server running in Azure VMs as the validation target. For a customer PoC, we
> should connect one of their real non-Azure SQL hosts or build a separate
> non-Azure SQL lab.

Avoid:

> SQL did not work.

Avoid:

> This demo validates Arc-enabled SQL Server on the simulated on-prem VMs.

## Open work if SQL becomes a must-have live beat

1. Stand up a real non-Azure SQL Server 2016+ host.
2. Confirm network access to Arc and Arc Data Processing endpoints.
3. Run the documented `WindowsAgent.SqlServer` extension install.
4. Validate SQL Server - Azure Arc resource creation.
5. Capture BPA timing and Defender behavior.
6. Add a separate SQL-specific runbook once that path is proven.
