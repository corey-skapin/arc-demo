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

| What you want | Repo path | Boundary |
| --- | --- | --- |
| Real SQL instance/database/query activity in this existing lab | [Real SQL workload](sql-engine-workload.md) | SQL 2022 Developer, pinned media and licence terms; no Arc SQL extension/Paid/BPA |
| Functional nested SQL/Arc demo | [Scratch nested guest](nested-sql-demo.md) | Real Windows/SQL/Arc guest; Azure-hosted nested demo, not blanket support validation |
| Supported SQL Server enabled by Azure Arc product validation | Supported non-Azure SQL host | Confirm the documented host/licensing requirements; do not extrapolate from this demo |

SQL-shaped simulator events (the old events-only worker) were retired and never proved a SQL engine.

The scratch build is primary; Jumpstart is a manual alternative. The
[nested runbook](nested-sql-demo.md#alternative-jumpstart-prebuilt-image) owns the
side-by-side comparison and live timings, without changing this support boundary.

## Customer-safe wording

> This is a real SQL Server workload on our Arc-monitored lab server.
> We show actual engine/database query results and transaction-derived events.
> It does not validate Arc-enabled SQL Server inventory, BPA or Defender for SQL.
> A supported Arc SQL product demo needs a suitable non-Azure SQL host.

Never use simulated SQL events as evidence of actual database queries.
Engine setup, telemetry collection and fault/recovery are separate steps.
