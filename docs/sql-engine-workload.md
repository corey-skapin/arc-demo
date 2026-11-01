# Real SQL workload on the existing lab VM

Use this optional path for **SQL Server 2022 Developer on `win-sql-01`**.
For the nested Arc SQL build, use [nested-sql-demo.md](nested-sql-demo.md).
This engine-only path does not install Arc SQL/BPA or change Defender pricing.
Inherited estate automation may independently install Defender extensions;
leave that protection intact. See [the support boundary](sql-arc-spike.md).

## Approval, fit and media

Use the retained tenant/subscription/skin and existing Windows host. Do not resize
or redeploy the estate just to prepare SQL.

The helper requires Windows Server 2016+, .NET Framework 4.7.2+, a member or
standalone server, 4 GiB RAM, 2 GiB available RAM and 10 GiB free system disk.
Existing MSSQL services, an active installer, pending reboot or file rename
stop installation. A host name alone does not establish available capacity.

Obtain approved **SQL Server 2022 Developer ISO** media and accept its actual
licence terms before installation. Developer is for development/test/demo, not
production. Record the ISO SHA256 privately and stage it on the selected guest.
The helper checks the hash, Microsoft signature and SQL major version 16.
There is no automatic download, paid-edition fallback, reboot or resize.

Before installing, prevent automatic Arc SQL connection on this engine-only
host. The helper's `ProtectArcSql` action adds only
`Microsoft.AzureData/WindowsAgent.SqlServer` to the local blocklist and checks
readback. It preserves other entries, agent mode and running services.
This is a separate requested configuration change, not part of Status or wake.
The installation flag confirms this choice; the actual local block is also read.

The documented `ArcSQLServerExtensionDeployment=Disabled` tag can take up to
eight hours to propagate. A Failed SQL extension ARM row can represent a blocked
attempt rather than an installed extension. Do not remove security extensions,
change inherited policy or clear failed rows merely to improve demo appearance.

## Install once

`@target` contains explicit `SubscriptionId`, `TenantId` and private `SkinPath`.
The normal wrapper selects the host from retained deployment inventory.

```powershell
.\scripts\Invoke-SqlEngineOnArc.ps1 @target -MachineName win-sql-01 `
  -Action ProtectArcSql -WhatIf
# Run without WhatIf only when that host-specific change is requested.

.\scripts\Invoke-SqlEngineOnArc.ps1 @target -MachineName win-sql-01 `
  -Action Install -MediaIsoPath <APPROVED_GUEST_ISO_PATH> `
  -MediaSha256 <APPROVED_SHA256> -AcceptDeveloperLicenseTerms `
  -ArcSqlAutoConnectOptOutConfirmed `
  -ResultPath .\.local\sql-engine-install.json -WhatIf
# After installation is requested and terms accepted, run without WhatIf.
```

WhatIf checks context/inventory without guest execution.
`-GuestScriptOutputPath <private-file.ps1>` exports the script offline; export is
not execution. Passwords and runtime IDs must stay out of tracked files.

Setup creates named instance **ARCDEMO** and database **ArcDemoOrders**, using
Windows authentication for SYSTEM. SQL TCP/Named Pipes are off; SQL Agent and
Browser are disabled. No public listener, `sa` password or other instance changes
are introduced. Loopback diagnostic listeners can still exist.

The SQL buffer pool is capped at 512 MB and MAXDOP at 1; this is not a total
process-memory cap or performance benchmark. The database uses SIMPLE recovery,
128-MB data/64-MB log caps and at most 1,000 orders.

The worker commits an INSERT, trims old rows and reads the database every
15 seconds. Event `6000` Information from `ArcSqlEngineDemo` is emitted roughly
once per minute only after a real commit/read. Event `6200` Error records worker
failure; no synthetic incident is needed for healthy activity.

## Status and repeat behavior

```powershell
.\scripts\Invoke-SqlEngineOnArc.ps1 @target -MachineName win-sql-01 `
  -Action Status -ResultPath .\.local\sql-engine-status.json
```

Status is a guest Run Command, not just ARM metadata. It queries engine
edition/version, instance, connection, memory/MAXDOP, row count and last commit.
`evidence.status=pass` needs a running worker and a commit within 120 seconds;
stale activity is pending. Status does not install, start or repair SQL.

A matching ready installation is a no-op on repeat. It neither upgrades the
worker nor restarts an intentionally stopped task. Foreign instances, databases,
tasks, paths or source hashes are rejected.

Setup exit 3010 records `pending-reboot` without rebooting. A 20-minute timeout
leaves the active installer and mounted media alone. Inspect failed/unknown
setup before another attempt. Recorded exit 0 can resume database/task
initialization without another installer; 3010 needs an observed later boot,
clear reboot flags and no active installer.

### Updating an existing owned worker

Repository edits do not update an installed worker. If an update is requested,
back up the installed script, manifest and task definition/state first.
Verify the task belongs to this workload and no probe is active, then stop only
that task. Stage and parse the replacement, verify its hash, update the script
and the manifest's `scriptSha256`, and restore the task's original enabled/running
state. Keep SQL, data and other services unchanged. Verify fresh Status and
commit activity; if replacement fails, leave the task stopped until the saved
files can be restored consistently.

## Real lock-timeout incident

The incident helper is available, but **the SQL alert deployment and end-to-end
alert/SRE rehearsal have not been run**. They require a separate requested window.

`-Action Incident` requires the healthy orders worker and owned probe table.
One SQL transaction takes a row lock; another waits and actually returns
error **1222** with `SET LOCK_TIMEOUT 5000`. The helper captures blocker/victim
session IDs, `LCK_M_*` wait type and resource from SQL.

The blocker uses a server-side 12-second WAITFOR then ROLLBACK. Both transactions
roll back; a database application lock prevents concurrent probes. The worker
and Orders table are not stopped or locked by this demonstration.
Client waits are bounded, and cleanup must verify unchanged probe value,
no remaining owned sessions and a healthy worker before recording recovery.
Unknown cleanup is an error. Never kill historical session IDs from old events.

| Event | Level | Meaning |
|---|---|---|
| `6000` | Information | Real normal order commit/read |
| `6201` | Error | Actual 1222 with SQL blocking evidence |
| `6001` | Information | Rollback/session cleanup and worker health verified |

Incident descriptions are JSON with `scenario=sql-lock-timeout`, `incidentId`,
state, instance/database, blocker/victim IDs, wait details, SQL error and timestamp.
A dated event does not establish a currently blocked session.

For a requested rehearsal: verify SQL Status and fresh `6000`, deploy only
`Set-SqlIncidentAlert.ps1` with the existing workspace/Action Group, confirm the
companion's Review-only SQL route, run one Incident, then inspect same-incident
events, actual alert/investigation and post-incident Status.
The alert is `al-<prefix>-sql-lock-timeout`, **Sev2**, Count > 0,
one-minute evaluation and a 15-minute window. It has ongoing alert costs.
The probe usually recovers before the alert; the story is evidence correlation,
not an ongoing outage or automatic SRE remediation.

## Park, wake and stop

Normal lifecycle preserves the engine, database and task. The worker waits up to
600 seconds for service/connection and recovering-database startup; it does not
restart SQL. Ownership, authentication and incompatible-schema errors fail
immediately. Failures emit `6200` with their phase before the task exits.

After wake, verify actual Status; Arc Connected alone is not application health.
An intentionally stopped worker remains disabled. `-Action Start` enables/starts
only the owned worker, while `-Action Stop` stops/disables it and retains SQL/data.
Neither action reinstalls SQL or resets another workload.

Complete an active probe before parking. Hibernation retains alert/monitoring
and their costs; normal full removal deletes the demo disks and SQL alert.
There is no engine uninstall, DROP DATABASE or data-recovery shortcut.

For presenter links, save passing `sql-engine-status.json` alongside
`.local/demo-context.json`, set its optional `sqlMachineResourceId`, and regenerate
the [single presenter guide](runsheet.md). The generator checks host and evidence;
without that optional context the SQL beat is skipped.
Event collection needs the narrow source-specific DCR selectors; repository
source does not establish that a live DCR was updated or new events ingested.

## Official guidance

- [SQL 2022 requirements](https://learn.microsoft.com/sql/sql-server/install/hardware-and-software-requirements-for-installing-sql-server-2022?view=sql-server-ver16)
- [Command-line setup](https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt?view=sql-server-ver16)
- [Automatic Arc SQL connection](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-autodeploy)
- [Agent block lists](https://learn.microsoft.com/azure/azure-arc/servers/security-extensions#allow-lists-and-block-lists)
- [SQL lock timeout](https://learn.microsoft.com/sql/t-sql/statements/set-lock-timeout-transact-sql)

Mocked tests cover behavior, not live SQL setup, ingestion or alert delivery.
