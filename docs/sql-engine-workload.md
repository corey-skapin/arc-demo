# Real SQL workload on the existing lab VM

Use this optional path for **SQL Server 2022 Developer on `win-sql-01`**.
For the nested Arc SQL build, use [nested-sql-demo.md](nested-sql-demo.md).
This engine-only path does not install Arc SQL/BPA or change Defender pricing.
Inherited estate automation may independently install Defender extensions;
leave that protection intact. See [the support boundary](sql-arc-spike.md).

## Fit and media

Use the retained tenant/subscription/skin and existing Windows host. Do not resize
or redeploy the estate just to prepare SQL.

The helper requires Windows Server 2016+, .NET Framework 4.7.2+, a member or
standalone server, 4 GiB RAM, 2 GiB available RAM and 10 GiB free system disk.
Existing MSSQL services, an active installer, pending reboot or file rename
stop installation (the error lists what is pending; to clear a routine leftover,
restart the host once with `az vm restart` and rerun, see
[the recipe](troubleshooting.md#sql-preparation-reports-a-pending-file-rename)).
A host name alone does not establish available capacity.

Stage the pinned **SQL Server 2022 Developer ISO** on the selected guest with
`scripts\Stage-DemoMedia.ps1 -AcceptSqlDeveloperTerms`; the switch accepts the
Developer licence terms and records that acceptance privately. Developer is for
development/test/demo, not production. [config\demo-media.json](../config/demo-media.json)
holds the public Microsoft URL, size, SHA-256 and licence URL, and only a file that
matches its pin takes its final name. The SQL helper still checks the hash,
Microsoft signature and SQL major version 16 itself.
It performs no download, paid-edition fallback, reboot or resize.

Before installing, prevent automatic Arc SQL connection on this engine-only
host. The helper's `ProtectArcSql` action adds only
`Microsoft.AzureData/WindowsAgent.SqlServer` to the local blocklist and checks
readback. It preserves other entries, agent mode and running services.
This is a separate configuration change, not part of Status or wake.
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
# Then run it without -WhatIf.

# Stage the pinned ISO (about 1.1 GiB) on the running host and verify its size and SHA-256.
$media = .\scripts\Stage-DemoMedia.ps1 @target -MachineName win-sql-01 `
  -Media sql-server-2022-developer -Destination C:\DemoMedia `
  -AcceptSqlDeveloperTerms -Confirm:$false
$sql = $media.items[0]

.\scripts\Invoke-SqlEngineOnArc.ps1 @target -MachineName win-sql-01 `
  -Action Install -MediaIsoPath $sql.path `
  -MediaSha256 $sql.sha256 -AcceptDeveloperLicenseTerms `
  -ArcSqlAutoConnectOptOutConfirmed `
  -ResultPath .\.local\sql-engine-install.json -WhatIf
# Then run it without -WhatIf.
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

To update only the **incident emitter**, use
`Invoke-SqlEngineOnArc.ps1 -Action UpdateIncidentEmitter` with the same explicit
subscription, tenant, machine and private skin, first with `-WhatIf`.
This does not run an incident. It requires healthy owned SQL/task/hash evidence
and refuses executable changes to existing normal-worker functions. Only line
endings and literal `throw` diagnostic wording may differ; executable string
interpolations, SQL, conditions and timing remain exact. It keeps the worker
running: its order-processing behavior is unchanged.

The helper stages/parses/hashes the candidate and holds the same exclusive SQL
application lock as the incident. With no owned incident sessions and exactly
one unchanged checkpoint row, it transactionally renames an existing
`dbo.IncidentProbe` to `dbo.OrderProcessingCheckpoint`; a matching new table is
accepted, but missing/both tables, incompatible columns or foreign-key references
fail closed. New installations create only the new name.
It atomically replaces each owned script/manifest file, retains their previous
copies in the owned directory and commits the SQL rename only after file/hash
readback. Pre-commit failure rolls back the rename and restores replaced files.
An ambiguous commit is an error requiring inspection, not an automatic retry or
rollback. Post-update Status must pass; verify a subsequent fresh commit/`6000`
before presentation. This update changes no SQL service, task, credentials,
policy, monitoring or workload fault setting.

The installation manifest and outer operation result remain schema v1; only
the structured incident **event payload** moves to v2.

For broader **normal-worker** changes, the emitter-only action is not an upgrade
shortcut: back up the installed script, manifest and task definition/state first.
Verify the task belongs to this workload and no probe is active, then stop only
that task. Stage and parse the replacement, verify its hash, update the script
and the manifest's `scriptSha256`, and restore the task's original enabled/running
state. Keep SQL, data and other services unchanged. Verify fresh Status and
commit activity; if replacement fails, leave the task stopped until the saved
files can be restored consistently.

## Real lock-timeout incident

The first two live runs each proved one real `1222`/`LCK_M_X`, bounded
rollback, ingested detection/recovery events, a Sev2 alert, Action Group execution
and an automatic Review-only SRE investigation. Times are UTC.

| Date | Detected | Recovered | Alert fired | SRE thread created | Final narrative |
| --- | --- | --- | --- | --- | --- |
| 1 November 2026 | 23:24:21 | 23:24:28 | 23:25:12 | 23:26:22 | 23:27:47 |
| 2 November 2026 | 00:17:51 | 00:17:59 | 00:18:49 | 00:19:26 | 00:20:57 |

Neither run used a manual incident chat or SQL repair. Independent before/after
checks verified healthy orders, an unchanged probe and zero owned sessions.
The DCR change adds only the source-specific `6000`/`6001` selectors and keeps
existing sources and associations. The second run used a temporary alert rule and
merge window, so it does not prove a default repeat would create a new incident
inside the normal three-hour cooldown.

**Evidence limits:** Action Group execution does not prove email receipt.
Complete built-in query outputs were truncated in the audit and absent from
message results, so full raw-query verification remains unproven. Do not equate
aggregate rows with sample counts.
This is self-recovery followed by investigation, not automatic SRE remediation.

Before the v2 run on 2 November, the installed source matched the repo, the
renamed checkpoint was zero with no legacy table or owned incident sessions, and
orders/`6000` activity continued. The single v2 run then proved the deployed
event-to-alert path:

| Evidence | UTC |
| --- | --- |
| Actual `6201` detection | 01:50:24.539 |
| Verified cleanup and `6001` recovery | 01:50:31.921 |
| Both events ingested | 01:50:55.170 |
| Exact temporary-rule Sev2 alert fired | 01:51:39.324 |
| Action Group execution recorded | 01:51:40.557 |
| Independent healthy guest/checkpoint/session check | 01:54:07 |

Both incident payloads contained exactly the twelve v2 fields listed below, with no
`scenario` or `maxBlockSeconds`; the detected error was `1222`, wait `LCK_M_X`
and observed session lock timeout `5000` ms. The exact deployed alert KQL matched
one detection for this incident. Post-recovery checks found a fresh orders
commit, the worker running/enabled, checkpoint value zero, no owned sessions,
the legacy table absent and the installed source matching the repo.
The run used a temporary rule and merge window, not default repeated-alert
behavior. An alert remaining Fired during its lookback is not proof that blocking
remains active. These checks prove v2 emission, ingestion and alert routing, not
SRE narrative correctness, email receipt or automatic remediation.

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
The probe self-cleans within the invocation. Do not use `-Action Stop` to clear
it: that stops the normal orders worker instead.

| Event | Level | Meaning |
| --- | --- | --- |
| `6000` | Information | Real normal order commit/read |
| `6201` | Error | Actual 1222 with SQL blocking evidence |
| `6001` | Information | Rollback/session cleanup and worker health verified |

Events `6201` and `6001` now carry this exact JSON v2 field set:
`schemaVersion`, `incidentId`, `state`, `instance`, `database`,
`blockerSessionId`, `victimSessionId`, `waitType`, `waitResource`,
`sqlErrorNumber`, `lockTimeoutMs`, `observedAtUtc`.
The helper reads `lockTimeoutMs` from the actual victim session's
`@@LOCK_TIMEOUT` and takes the error number from the caught SQL exception;
it does not emit configured scenario/duration or a promised cleanup outcome.
Recovery is a separate observed event after the existing cleanup/health gates.
A dated event does not establish a currently blocked session. The two runs in the
first table used the v1 payload; only the later v2 run exercised this field set.

To run the incident:

1. Verify SQL Status and a fresh `6000`.
2. Deploy only `Set-SqlIncidentAlert.ps1` with the existing workspace and Action
   Group.
3. Confirm the companion's Review-only SQL route.
4. Run one `-Action Incident`.
5. Inspect the same-incident events, the actual alert and investigation, and
   post-incident Status.

The alert is `al-<prefix>-sql-lock-timeout`, **Sev2**, Count > 0,
one-minute evaluation and a 15-minute window. It has ongoing alert costs.
Its helper uses the same explicit nested-parent/keep-parked skin selection as
lifecycle; preview does not wake those hosts. The stateful rule auto-mitigates
and has no additional action-muting duration; the companion's incident merge
window is a separate setting, not a notification-delivery guarantee.
The probe usually recovers before the alert; the story is evidence correlation,
not an ongoing outage or automatic SRE remediation.

The v2 alert requires the exact Arc ID, provider `ArcSqlEngineDemo`,
event `6201`, `schemaVersion=2`, `state=detected` and actual error `1222`;
there is no scenario-name predicate. Keep its title unchanged because the
companion routes on it. To correct only the description of an
existing canonical SQL/LOB rule, use `Set-ArcWorkloadAlertDescription.ps1`
with explicit subscription/tenant, `-Workload Sql|Lob`, machine and prefix.
Preview first. It sends only `properties.description`, verifies all other
configuration/tags and discloses Azure's read-only API-version metadata.
LOB deployment text is maintained by the companion's alert helper.

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

To get SQL links in the runsheet, save the passing `sql-engine-status.json` alongside
`.local/demo-context.json`, set its optional `sqlMachineResourceId`, and regenerate
the [runsheet](runsheet.md). The generator checks host and evidence;
without that optional context the SQL beat is skipped.
Event collection needs the narrow source-specific DCR selectors; repository
source does not establish that a live DCR was updated or new events ingested.

## Official guidance

- [SQL 2022 requirements](https://learn.microsoft.com/sql/sql-server/install/hardware-and-software-requirements-for-installing-sql-server-2022?view=sql-server-ver16)
- [Command-line setup](https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt?view=sql-server-ver16)
- [Automatic Arc SQL connection](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-autodeploy)
- [Agent block lists](https://learn.microsoft.com/azure/azure-arc/servers/security-extensions#allow-lists-and-block-lists)
- [SQL lock timeout](https://learn.microsoft.com/sql/t-sql/statements/set-lock-timeout-transact-sql)
- [Current session lock timeout](https://learn.microsoft.com/sql/t-sql/functions/lock-timeout-transact-sql)
- [Rename an owned table](https://learn.microsoft.com/sql/relational-databases/tables/rename-tables-database-engine)
- [Description-only alert update](https://learn.microsoft.com/rest/api/monitor/scheduled-query-rules/update)

Mocked tests cover behavior, not live SQL setup, ingestion or alert delivery.
