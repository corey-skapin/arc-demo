# Real SQL workload on the existing lab VM

This optional operator procedure installs a **real SQL Server 2022 Developer**
engine and small orders database on a retained Windows lab VM. It does **not**
install SQL Server enabled by Azure Arc, BPA, Defender for SQL or a SQL extension.
Independent discovery services and inherited security policies can still create
extension resources; the helper does not disable those policies.
The [support decision](sql-arc-spike.md) keeps those experiences distinct.
The [SQL-shaped simulator](sql-workload-simulation.md) is not engine proof.

## Approval, fit and media

Use the explicit retained tenant/subscription/skin and selected host; never
redeploy or resize the fleet just for SQL. The default candidate is `win-sql-01`
(Windows Server 2022, 2-vCPU/8-GiB default SKU). Actual OS, current headroom,
existing instances and pending setup/reboot must be checked under separately
approved guest-read scope. A host name is not proof of capacity or installation.

SQL 2022 supports Windows Server 2016+ and requires .NET Framework 4.7.2.
This helper additionally requires a member/standalone server, 4 GiB total RAM,
2 GiB available RAM and 10 GiB free system-disk space. A recorded pending reboot
or file rename blocks installation; never delete the flag, bypass setup rules
or reboot without approval.

Obtain **SQL Server 2022 Developer ISO media** through the operator's legitimate
[Microsoft downloads](https://www.microsoft.com/sql-server/sql-server-downloads)
or existing authorized media source. The downloads page can default to a newer
release; do not substitute it for the approved 2022 media.
Read the actual [SQL Server 2022 Developer licence terms](https://www.microsoft.com/content/dam/microsoft/usetm/documents/sql-server/sql-server-2022-developer-express-evaluation/retail-packaged/SQLServer2022_SQLServer2022DeveloperExpressEvaluation_English.pdf)
and the notice supplied with that media, then obtain the user's acceptance
**before** passing the flag. The media notice can link to Microsoft's full terms
rather than contain them; review the Developer provisions, not Evaluation rights.
Selecting this architecture is not accepting unseen terms or approving a download.
Stage the approved ISO on the guest only under separate upload/download consent.
Record its SHA256 privately; the helper checks it and Microsoft's setup signature
and major version. There is no bootstrap download, arbitrary URL or paid-edition
fallback. Approved media must actually be Developer, not Evaluation/Enterprise.

Developer is for **development/test/demonstration, not production**.
No SQL licence fee does not mean a free lab: existing VM/disk/monitoring charges,
CPU/I/O, setup/media footprint and added event ingestion still apply.
The helper makes no VM/disk resize, new Azure resource or Defender pricing change.
Existing subscription SQL VM auto-registration policy can operate independently;
do not confuse SQL IaaS registration with Arc SQL or change it incidentally.

**Before installation, review effective Arc SQL automatic-connection opt-out.**
Arc can automatically install its SQL extension when it discovers a new engine;
merely omitting our old extension command is not protection.
Microsoft documents `ArcSQLServerExtensionDeployment=Disabled` or an extension
blocklist alternative in [automatic connection management](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-autodeploy?view=sql-server-ver17#opt-out-of-automatic-connecting).
An opt-out tag change can take up to eight hours to take effect on existing
servers. Inspect the applicable configuration under approved read scope; any
needed tag/agent policy change needs separate approval and propagation evidence.
Do not install while the effective opt-out is unknown or still propagating.
This helper uses the narrowly scoped local blocklist option, with separate
approval for `-Action ProtectArcSql` on only the selected host. It appends
`Microsoft.AzureData/WindowsAgent.SqlServer` using `--add`, preserves existing
allowlist/blocklist/mode and running Arc services/AMA process, and verifies
readback. Conflicts/unknown formats fail closed; no wildcard, mode change,
service restart or automatic rollback. This blocks local SQL-extension
install/update/upgrade attempts, not subscription policy assignments or provider
registration. It does not remove a pre-existing SQL extension.
Installation requires both `-ArcSqlAutoConnectOptOutConfirmed` and an actual
read of that local block. The flag never grants permission to change policy.

### Automatic extension attempts and inherited security

An observed installation produced a **Failed** `WindowsAgent.SqlServer` ARM
extension row whose error explicitly confirmed the local block. That row is
not proof that the Arc SQL guest extension installed. Inspect actual publisher,
type, provisioning state and error; ARM-shaped CLI results put these under
`.properties`. Unknown response shapes must not be interpreted as absence.
The documented opt-out tag can prevent the automatic-connection producer after
propagation, but it does not remove existing rows or exempt security policy.
If separately approved, merge `ArcSQLServerExtensionDeployment=Disabled` on
only the selected Arc machine, preserve all other tags and verify readback.
Readback proves the tag was saved, not that the producer's cache has expired.
Keep the effective local SQL-only block during propagation.

Removing only an explicitly approved Failed SQL extension row is a separate
normal delete, never a Defender uninstall or a force-delete. Verify its exact
ID, publisher/type and Failed state immediately before submission; preserve
the other extensions and read back the outcome. A disconnected machine can
leave deletion incomplete: stop, report it and do not replay the delete.
After separately approved normal activation, inspect whether that same request
completed when the agent reconnected. Activation is not permission for another
delete or any incident.

The same installation independently triggered **MicrosoftDefenderForSQL**:
publisher `Microsoft.Azure.AzureDefenderForSQL`, type
`AdvancedThreatProtection.Windows`. Activity claims, assignment identity and
the correlated policy deployment traced it to an existing subscription security
assignment. Its DeployIfNotExists rule targets Windows Arc machines with
`mssqlDiscovered=true`; the inspected rule has no host opt-out tag. This is
Defender protection, not successful Arc SQL registration. A Succeeded extension
with a disconnected channel or empty instance list proves neither active SQL
coverage nor a particular charge.

**Retain policy-required security by default.** Do not uninstall or block its
sensor, falsify discovery, disable subscription protection or change inherited
assignments to make an engine-only demo appear clean. A genuinely required
host-only exception needs the security/policy owner's decision. Azure Policy
supports an [individual-resource exemption scoped to an initiative member](https://learn.microsoft.com/azure/governance/policy/concepts/exemption-structure),
with exemption-write and assignment-exempt permissions; this is a reviewed
exception, not an automatic setup step or a guarantee against other producers.
The documented [resource-level Defender uninstall](https://learn.microsoft.com/azure/defender-for-cloud/disable-sql-on-machines#disable-defender-for-sql-servers-on-machines-at-the-resource-level)
does not itself resolve a policy that requires redeployment. The exact Arc
machine resource-level `SqlServers` pricing GET was rejected as unsupported;
no pricing write was attempted. Do not assume a VM pricing toggle or Arc SQL
opt-out supplies this exception.

## Install once, with explicit approval

The assistant/operator supplies already confirmed values; these are not presenter
steps or permission to operate a live host:

```powershell
.\scripts\Invoke-SqlEngineOnArc.ps1 @target -MachineName win-sql-01 `
  -Action Install -MediaIsoPath <APPROVED_GUEST_ISO_PATH> `
  -MediaSha256 <APPROVED_SHA256> `
  -ResultPath .\.local\sql-engine-install.json -WhatIf

# Only after scoped approval and completed opt-out review:
# add AcceptDeveloperLicenseTerms and ArcSqlAutoConnectOptOutConfirmed; remove WhatIf.
```

`@target` contains the explicit `SubscriptionId`, `TenantId` and retained
`SkinPath`. WhatIf checks context/retained inventory but never runs a guest.
`-GuestScriptOutputPath <private-file.ps1>` exports offline without Azure access;
it is not evidence that the exported script was executed.

The isolated named instance is **ARCDEMO**, database **ArcDemoOrders**.
Setup uses Windows authentication for the SYSTEM execution/worker identity,
local shared-memory access, TCP/Named Pipes off and SQL Browser/Agent disabled.
No `sa` password, public listener, firewall, cloud IAM or other instance change.
SQL can retain loopback-only diagnostic listeners even with TCP data access
disabled; "no public listener" does not mean there are no listening sockets.
SQL buffer-pool memory is capped at 512 MB and MAXDOP at 1; this is **not** a
total-process memory cap or a performance benchmark.

The owned database uses SIMPLE recovery, a 128-MB data-file/64-MB log-file cap and
at most 1,000 order rows. The worker commits an INSERT, bounds old rows, then reads
the database every 15 seconds. A `6000` Information event from `ArcSqlEngineDemo`
is emitted roughly once per minute **only after real commit/read success**;
`6200` Error reflects actual worker failure. No synthetic fault is required.

On startup the worker verifies its ready manifest, exact script hash and owned
task before waiting up to **600 seconds per scheduler attempt** for the SQL
service/connection and database to become ready. Polls do not start or restart
SQL. Only bounded connection-startup errors and the database's transient
Recovering state are retried; authentication, permission, missing/foreign
database, paused service and incompatible engine/schema fail closed.
Engine/database ownership checks still run before the first transaction.
Terminal failures emit `6200` with `phase=ownership|startup|validation|transaction`
and the error, then fail the task. Existing scheduler restart settings remain
unchanged; no commit event is emitted until an actual transaction succeeds.

## Evidence and repeat behavior

```powershell
# Status is a guest Run Command; include it in the approved observation scope.
.\scripts\Invoke-SqlEngineOnArc.ps1 @target -MachineName win-sql-01 `
  -Action Status -ResultPath .\.local\sql-engine-status.json
```

Status SELECTs the actual engine edition/version, instance, Windows/shared-memory
connection, configured memory/MAXDOP, database row count and last commit.
`evidence.status=pass` requires a running worker and a commit within 120 seconds.
Stale/missing activity is pending, not fresh application proof.
No SELECT here installs, starts or repairs the engine.

An owned ready install with matching media/script hashes is a no-op on repeat;
it does not restart an intentionally stopped worker or upgrade files.
Foreign instances/databases/tasks/directories fail closed. Initial installation
refuses any existing MSSQL service, rather than side-by-side setup that could
change the shared SQL Browser service. Setup exits are checked; `3010` records
`pending-reboot` and stops without rebooting.
A 20-minute setup timeout leaves the running installer/media alone.
`installing`, failed or unknown setup state needs reviewed diagnosis, never replay.
An owned `initializing` phase with recorded setup exit 0 can finish database/task
preparation on an explicitly requested Install rerun without another installer.
Recorded `3010` can resume only after an observed later boot, clear reboot flags
and no active installer; the helper never causes that reboot.
Foreign/ambiguous partial database state still fails rather than being adopted.

### Updating an existing owned worker

Changing repository source does not upgrade the installed worker. Install
reruns still enforce the recorded script hash and must not be used to overwrite
an older version. Review and approve a host-specific update before uploading
or changing the installed file; no reboot or engine restart is required.

1. Freeze the expected old and new SHA256 values privately. Read the selected
   host's ready manifest, actual installed hash, task action/principal/settings,
   SQL identity/database ownership and current worker enabled/running state.
   Stop on drift or a foreign/active incident; do not infer ownership by name.
2. Record a private update journal and back up the exact old worker bytes,
   manifest bytes and task definition/state. Verify both backup hashes. Stage
   the approved new worker separately, verify its new hash and PowerShell 5.1
   parse before replacing any installed file.
3. Disable only the owned task and stop its current instance with a bounded
   wait. Verify it is stopped and no owned probe is active. SQL, data, other
   tasks/services and Arc/security configuration remain untouched.
4. Recheck old installed/manifest hashes for concurrent changes. Replace the
   worker from the verified stage, then replace the manifest while preserving
   every field except `scriptSha256`. Verify new installed hash and manifest
   agreement before any task execution. A cross-file interruption is not an
   atomic update: leave the task stopped and inspect the journal, never replay.
   On Windows PowerShell 5, use explicit unique non-null backup paths for each
   `File.Replace` call and verify the displaced hashes; a null backup argument
   can bind as an invalid empty path. Validate replacement and rollback locally,
   including a real failure between the two file replacements, before release.
5. Restore the original enabled state and start only if originally running.
   Require fresh Status pass and actual `6000`; an originally disabled/stopped
   worker remains so. Keep backups and record dated evidence.
6. If update validation fails, report it explicitly. A reviewed rollback stops
   the owned task, first verifies the exact new/partial hashes against its
   journal, then restores both verified old worker and old manifest bytes.
   Verify their original hashes before restoring original task state. Require
   fresh proof if it was running; rollback to the old worker does not claim
   the startup race is fixed. Unknown state needs diagnosis, not forced restore.
   If both files already match their original hashes, do not replace them:
   verify backups and restore only the original task state. Preserve the failed
   journal and use a separately reviewed update attempt, never replay it.

These are reviewed operator steps, not an automatic migration performed by
Status, activation, readiness, installation or this guide. Deterministic
delayed-engine tests are not proof of a live reboot; obtain separate approval
before any future cold-start rehearsal.

The core DCR source includes only
`Application!*[System[Provider[@Name='ArcSqlEngineDemo'] and (EventID=6000) and (Level=4)]]`
and the equivalent source-specific `EventID=6001`, `Level=4` recovery selector,
in addition to existing selectors. Actual error `6201` uses the existing
Application Error selector. This does **not** change an existing live DCR by
itself. Apply only those narrow additions with scoped collection/cost approval,
fresh concurrency-safe preservation and actual post-change ingestion proof.
Do not redeploy the whole lab merely to collect the SQL event.

After successful actual Status evidence, the preparing operator adds
`sqlMachineResourceId` to `.local/demo-context.json` and regenerates the guide.
The generator requires the adjacent real `sql-engine-status.json`, exact host,
pass state, Developer/version/database and bounded query values.
Without that optional context the SQL beat is explicitly skipped.
The [single presenter guide](runsheet.md) links the dated query proof and scopes
fresh Event rows to that exact host. It never silently claims current health.

## Real lock-timeout incident and automatic investigation

The approved rehearsal uses **real SQL sessions**, not a fabricated SQL event.
`-Action Incident` first requires a healthy orders worker and owned probe.
One transaction takes an exclusive row lock on `dbo.IncidentProbe`; another
actually waits, then returns SQL error **1222** after `SET LOCK_TIMEOUT 5000`.
The helper captures actual `sys.dm_exec_requests` blocker/victim IDs,
`LCK_M_*` wait type and wait resource before recording the error.

The blocker has a server-side **12-second WAITFOR then ROLLBACK** with TRY/CATCH
rollback; client waits are bounded and nonpooled connections are disposed on
success/failure. A database application lock prevents concurrent probes.
Both transactions roll back; there is no COMMIT on this probe, service stop,
Orders-table lock, database corruption, host-load loop or normal-worker restart.
Twelve seconds is the intended server wait, not an unconditional recovery SLA
on an unresponsive engine. Unknown cleanup is an error, never automatic retry.
Successful recovery requires unchanged probe value, zero remaining owned
sessions and a still-healthy orders worker. The action is not run by activation,
installation, readiness or generation of a presenter file.

| Provider/source | Event | Level | Meaning |
|---|---|---|---|
| `ArcSqlEngineDemo` | `6201` | Error | Observed actual 1222 plus captured SQL blocking evidence |
| `ArcSqlEngineDemo` | `6001` | Information | Rollback/probe/owned-session cleanup and orders health verified |
| `ArcSqlEngineDemo` | `6000` | Information | Normal real order commit/read, not an incident |

`RenderedDescription` is JSON with `schemaVersion=1`,
`scenario=sql-lock-timeout`, `incidentId`, `state=detected|recovered`, `instance`,
`database`, `blockerSessionId`, `victimSessionId`, `waitType`, `waitResource`,
`sqlErrorNumber` (1222 detected, 0 recovered), `lockTimeoutMs=5000`,
`maxBlockSeconds=12` and `observedAtUtc`.
No event is evidence of a current lock after its timestamp.

Operator preparation, within the approved deployment/rehearsal scope:

1. Complete prerequisites/media/terms and actual engine Status proof.
2. Verify the narrowly approved live DCR additions and fresh `6000` ingestion.
3. Use `Set-SqlIncidentAlert.ps1` to deploy **only** the optional
   `bicep/modules/sql-incident-alert.bicep`, with exact workspace/Action Group IDs.
   The existing Action Group must be enabled with a common-schema receiver;
   this helper never changes its receivers, IAM, DCR or the whole lab.
4. Have the companion SRE operator verify its distinct SQL Review filter,
   handler, managed resource scope and existing alert route before triggering.
5. Execute one `Invoke-SqlEngineOnArc.ps1 -Action Incident` on the exact prepared
   host and retain its private `ResultPath`. Verify same-`incidentId` events,
   actual Azure alert and actual SRE investigation, then post-incident SQL Status.

The distinct alert is `al-<prefix>-sql-lock-timeout`, display/title keyword
**Arc SQL lock timeout**, **Sev2**, Count greater than zero, one failing period,
one-minute evaluation and 15-minute window. Its canonical exact-host/source/JSON
query is in the Bicep module. It retains the existing workspace/Action Group;
one additional active log alert has an ongoing monitoring cost.

The probe normally self-recovers **before** the alert and SRE investigation.
The demonstration is historical evidence correlation and suggested next steps,
not SRE remediation or an ongoing orders outage. The SRE repository owns the
Review-only handler/filter, investigation and simple continuation guide.
Existing host Perf is context, not SQL wait counters; 60-second sampling need
not capture a 12-second probe. Do not invent a CPU spike or directly connect
SRE to SQL credentials/guest execution.

Repeated triggers in an already-fired window may not create a new alert.
Observe actual resolution and the SRE filter's cooldown; do not bypass either
or fabricate an investigation. Historical session IDs can be reused: never
kill a session based on these old events.

## Park, wake and stop

Normal Hibernate/Activate preserve the VM, HDD tier, SQL instance and database.
The SQL service and worker task are configured for automatic startup, but this
is not proof that the worker resumed. One observed wake of the original worker
launched the task before SQL reported ready for connections; the task returned 1
and remained Ready, enabled, with only pre-parking commits. The updated source
adds the bounded startup gate above, but an existing host needs the separately
reviewed worker migration before that change applies. Verify SQL separately, because Arc
readiness alone does not check this optional application. Diagnose a stale
worker read-only before any separately approved owned `-Action Start`; do not
replay installation, restart SQL or claim successful application recovery from
Arc readiness. See [SQL worker startup diagnosis](troubleshooting.md#sql-is-queryable-after-wake-but-the-worker-is-ready-with-stale-commits).
An explicitly stopped worker stays disabled across wake.

`-Action Stop` stops/disables only the verified owned worker and retains its
database/engine. `-Action Start` enables/starts that worker after engine/ownership
checks; it does not restart SQL or reset another workload.
There is no automatic DROP DATABASE, engine uninstall, snapshot, backup or
rollback guarantee. Such deletion/recovery needs a separate reviewed plan.
Normal approved lab removal retains its existing disk-deletion contract.
The SQL alert is in the existing Arc group, so normal removal deletes it.
Hibernate retains the alert/monitoring (and their costs); an in-flight probe
must finish and verify cleanup before parking, rather than resetting it.
The local SQL-extension block survives reboot/parking and is not cleared on wake.

## Official guidance and validation limits

- [SQL 2022 hardware/OS/.NET requirements](https://learn.microsoft.com/sql/sql-server/install/hardware-and-software-requirements-for-installing-sql-server-2022?view=sql-server-ver16)
- [Command-line setup and parameters](https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt?view=sql-server-ver16)
- [Installation/licensing planning](https://learn.microsoft.com/sql/sql-server/install/planning-a-sql-server-installation?view=sql-server-ver16)
- [Arc SQL unsupported configurations](https://learn.microsoft.com/sql/sql-server/azure-arc/overview?view=sql-server-ver16#unsupported-configurations)
- [Agent extension allow/block lists](https://learn.microsoft.com/azure/azure-arc/servers/security-extensions#allow-lists-and-block-lists)
- [Agent configuration and additive list updates](https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-config)
- [SQL lock timeout semantics](https://learn.microsoft.com/sql/t-sql/statements/set-lock-timeout-transact-sql)
- [Actual request/blocking DMV](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-requests-transact-sql)
- [Database recovery and non-transient states](https://learn.microsoft.com/sql/relational-databases/databases/database-states?view=sql-server-ver16)

Offline mocked tests are not SQL setup, database execution, wake/recovery or
fresh incident/alert/SRE ingestion proof. Those remain unverified until actually run.
