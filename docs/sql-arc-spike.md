# SQL support decision

This Azure-only lab Arc-enables Azure VMs using `MSFT_ARC_TEST=true`.
It can run a **real SQL engine/workload** on those VMs, but that is not supported
validation of **SQL Server enabled by Azure Arc**.

The current [Microsoft Arc SQL overview](https://learn.microsoft.com/sql/sql-server/azure-arc/overview#unsupported-configurations)
lists **SQL Server in Azure Virtual Machines** as unsupported. Genuine Arc SQL
inventory/BPA/Defender product validation belongs on a supported non-Azure host.
The [nested SQL demo](nested-sql-demo.md) instead runs a real Hyper-V guest on
an Azure parent and demonstrates actual SQL/Arc connection. This is a functional
demo, not production architecture or a support-certification claim.
Do not turn this constraint into the incorrect claim that SQL Server cannot run
on an Azure VM.

| What the presenter wants | Repo path | Boundary |
|---|---|---|
| Real SQL instance/database/query activity in this existing lab | [Real SQL workload](sql-engine-workload.md) | SQL 2022 Developer, approved media/terms; no Arc SQL extension/Paid/BPA |
| Historical lightweight SQL-shaped events only | [Simulator reference](sql-workload-simulation.md) | No engine or SQL query proof; label it accurately |
| Functional nested SQL/Arc demo | [Scratch nested guest](nested-sql-demo.md) | Real Windows/SQL/Arc guest; Azure-hosted nested demo, not blanket support validation |
| Supported SQL Server enabled by Azure Arc product validation | Supported non-Azure SQL host | Confirm the documented host/licensing requirements; do not extrapolate from this demo |

## Nested SQL demo prototype race

The **scratch build is the primary repo path** after its successful from-zero
run. The Jumpstart prebuilt image is a documented manual alternative. Keep the
working scripts and lifecycle, not the retired prototype review machinery.
This comparison does not change the base Azure-VM simulation's support boundary.

| Aspect | Scratch build | Prebuilt image |
|---|---|---|
| What it needs | Server 2022 media/BCDBoot, unattended Windows guest, SQL Developer media, retained private credentials, Arc connect and extension helpers | Jumpstart VHD, manual licence/OOBE, administrator password and static network; then Arc connect and SQL verification |
| What broke along the way | Server 2019 BCDBoot `c000003a`, PS5 informational stderr, command-count limit and cold DNS | Manual first-boot/OOBE and networking; invalid `Stop-VM -Shutdown` needed normal graceful Stop-VM |
| Time to a working setup | **45m44s** for the reported nested from-zero run | Not timed as an automated from-zero repo build |
| Repeatable stand-up | Passed from zero using the scratch scripts; primary path | Manual preparation remains required |
| Stand-down | Reported park about **4 minutes** | Uses the same skin-configured lifecycle after manual setup |

Per-step times and the final wake result belong in the short runbook, from
actual executor reports. Local tests do not establish a new live lifecycle proof.

## Retired mixed installation path

The old deployment `-InstallSql` branch mixed a real engine installation with
`WindowsAgent.SqlServer`, Paid licence metadata and BPA, using an unchecked
bootstrap/setup sequence and a shared SQL password.
It is **retired**, not a shortcut for the chosen workload.

`-InstallSql`, legacy `-SkipSqlInstall:$false` and a skin enabling SQL now fail
explicitly before deployment. Default/explicit skip remains supported.
`Deploy-ArcDemo.ps1` never installs SQL or adds Arc SQL/BPA.
Use `Invoke-SqlEngineOnArc.ps1` only after its separate installation/media/licence
approval. No current engine/installation claim follows from source presence,
SQL-capable host names, extension state or old spike logs.
Before installing, separately review effective Arc SQL automatic-connection
opt-out; Arc discovery can otherwise deploy the extension independently.
The workload helper requires explicit operator confirmation but never changes
tags or extension policy. See the [installation prerequisites](sql-engine-workload.md#approval-fit-and-media).

## Customer-safe wording

> This is a real SQL Server workload on our Arc-monitored lab server.
> We show actual engine/database query results and transaction-derived events.
> It does not validate Arc-enabled SQL Server inventory, BPA or Defender for SQL.
> A supported Arc SQL product demo needs a suitable non-Azure SQL host.

Never use simulated SQL events as evidence of actual database queries.
Keep engine setup, telemetry collection and fault/recovery consent separate.
