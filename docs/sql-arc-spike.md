# SQL Server / Arc SQL spike

**Reference/decision record, not an installation or presenter prerequisite.**
[The docs index](README.md) explains the default path; [runsheet.md](runsheet.md)
deliberately omits Arc SQL from this Azure-only lab's live evidence.

## Decision

Do **not** include **SQL Server enabled by Azure Arc** as a default or
customer-facing validated beat in this Azure-only lab.

It is still valid to install SQL Server on an Azure VM as a **workload simulation**
if we need SQL-shaped events, services, or operational signals. The unsupported
claim is narrower: do not present SQL Server running on an Azure VM as a supported
validation target for the **SQL Server enabled by Azure Arc** product experience.

The SQL story is important, but there are two separate cases:

| Case | Status | Demo stance |
|---|---|---|
| Real non-Azure server, for example customer Hyper-V/VMware/on-prem VM connected with Azure Arc | Supported by Microsoft docs when prerequisites are met | Good customer conversation and future lab path |
| SQL Server installed on an Azure VM in this repo | Valid as a local workload simulation | Good for SQL-shaped service/app/Event Log/Monitor signals if implemented reliably |
| SQL Server enabled by Azure Arc on this repo's Azure-VM-backed hosts | Not a supportable Arc SQL validation target because SQL Server in Azure Virtual Machines is listed as unsupported for SQL Server enabled by Azure Arc | Do not sell as validated; keep skipped by default |

The current script previously attempted to install SQL Server 2022 Developer on
the Azure-VM-backed Arc hosts and then add `WindowsAgent.SqlServer`. That combines
two different ideas: useful workload simulation and unsupported Arc SQL validation.
Future work should split them:

1. **SQL workload simulation** - acceptable in this repo if reliable.
2. **SQL Server enabled by Azure Arc** - out of scope for this repo because the
   hosts are Azure VMs.

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

Real non-Azure Hyper-V or VMware-hosted SQL servers can follow the Arc SQL path
when they meet its documented requirements. The all-Azure demo simulation must
not claim supported Arc SQL validation.

This reusable lab does **not** stand up a non-Azure VM for this demo. The
real Arc SQL path should remain a customer PoC / future sidecar note, not a
dependency for the reusable demo.

## Current repo implementation

`scripts\Deploy-ArcDemo.ps1` has an optional `-InstallSql` path:

1. Downloads SQL Server installer bootstrapper from `go.microsoft.com/fwlink/?linkid=2215158`.
2. Uses `SSEI.exe /ACTION=Download /MEDIAPATH=C:\SQL2022 /MEDIATYPE=ISO /QUIET`.
3. Mounts the ISO and runs `setup.exe` for the default `MSSQLSERVER` instance.
4. Installs the `WindowsAgent.SqlServer` Connected Machine extension with:
   - `SqlManagement.IsEnabled=true`
   - `LicenseType=Paid`
   - `AzureBestPracticesAssessment.IsEnabled=true`

That path is skipped by default. As written, it is not currently a reliable or
supportable shareable branch for this Azure-only lab because it tries to do both
SQL workload installation and Arc SQL extension registration.

Historical spike logs did not establish a clean SQL setup failure. They showed
earlier deployment idempotency failures such as
`osDisk.name` / managed disk SKU immutability and budget start-date updates. The
more recent live run symptom was a long-running SQL setup phase that did not
complete in the demo window.

## Supported ways to tell the SQL story

### Option A - SQL workload simulation inside this Azure-only lab

Use this if we need a SQL-flavoured operational signal without claiming Arc SQL:

- Prefer the existing lightweight [SQL-shaped workload simulator](sql-workload-simulation.md)
  on `win-sql-01`; it installs no SQL Server engine or Arc SQL extension.
- Emit Windows Application events, service state, and optional perf signals.
- Alert on the workload signal through Azure Monitor.
- Let SRE Agent diagnose the incident as a SQL workload on an Arc-enabled server
  simulation.
- Do **not** install or claim `WindowsAgent.SqlServer`.
- Do **not** show **Azure Arc > SQL Server** as validated evidence.

This is the recommended path for this demo if a SQL beat is needed.

### Option B - customer-realistic Arc SQL branch

Use this when the customer has, or the SE can provide, a real non-Azure Windows
Server 2016+ machine with SQL Server 2014+ installed.

1. Connect the machine to Azure Arc.
2. Verify outbound access to:
   - `aka.ms`
   - `*.web.core.windows.net`
   - `*.<region>.arcdataservices.com` on TCP 443
3. Only in that separately approved non-Azure SQL lab, register needed providers:

   ```powershell
   az provider register --subscription <SUB> --namespace Microsoft.HybridCompute
   az provider register --subscription <SUB> --namespace Microsoft.AzureArcData
   ```

4. With installation/licensing approval, install the SQL extension using settings
   appropriate to the real host's license (the example Paid setting is not a
   default licensing recommendation):

   ```powershell
   az connectedmachine extension create `
     --subscription <SUB> `
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

This is the right path for a customer-owned Hyper-V/VMware SQL Server estate, but
it is out of scope for this reusable Azure-only demo unless a customer PoC
provides the real host.

### Option C - keep this demo Azure-only and skip SQL

Use this for the shareable SE demo kit.

- Keep `-InstallSql` off.
- Treat `win-sql-01` / `win-sql-02` as SQL-capable Windows hosts in the narrative,
  not as Arc-enabled SQL Server instances.
- Use the Arc inventory, Defender, Update Manager, Machine Configuration, Monitor,
  and alerting beats.
- Mention that Arc-enabled SQL Server requires a real non-Azure SQL host for a
  supported lab validation. Do not make that a prerequisite for this demo.

### Option D - future separate SQL lab

Create a small separate SQL-specific lab that uses a non-Azure VM target:

- Hyper-V/VMware local VM, AVS with the supported AVS Arc deployment path, or
  another non-Azure cloud/host.
- Pre-install SQL Server from a known ISO or image controlled by the operator.
- Connect the host to Azure Arc.
- Install `WindowsAgent.SqlServer`.
- Validate inventory, Defender for SQL, BPA, and any SRE diagnostic hooks.

This is not planned for the current demo. Note it as an option only.

## Customer-safe wording

Use:

> Arc-enabled SQL Server is a strong follow-on for real on-prem SQL estates. This
> Azure-only lab can simulate SQL workload signals on an Arc-enabled server, but
> it does not validate SQL Server enabled by Azure Arc because that product path
> does not support SQL Server running in Azure VMs as the validation target. For a
> customer PoC, we should connect one of their real non-Azure SQL hosts.

Avoid:

> SQL did not work.

Avoid:

> This demo validates Arc-enabled SQL Server on the simulated on-prem VMs.

Also avoid:

> We cannot install SQL Server on an Azure VM.

## Open work if SQL becomes a must-have live beat

1. Decide whether the demo needs SQL-shaped workload signals.
2. If yes, explicitly deploy/validate the existing [workload simulator](sql-workload-simulation.md), which does not use `WindowsAgent.SqlServer`. Do not claim it ran merely because its source is present.
3. If a customer later wants true Arc SQL, use their real non-Azure SQL host and run
   the documented `WindowsAgent.SqlServer` extension install there.
