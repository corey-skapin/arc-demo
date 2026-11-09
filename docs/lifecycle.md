# Demo lifecycle and readiness contract

This page is the reference for parking, waking, removing and checking the lab. To
present without changing it, use [the docs index](README.md) and
[the runsheet](runsheet.md).

This is a deliberately un-hardened, single-region demo, not a production
reference. The maintained entry points are the PowerShell scripts. Always pass
your subscription and tenant at runtime; neither belongs in a skin.
Use the same skin/prefix throughout. CLI defaults are not changed by the scripts.

## Supported operations

There are three desired states: **Active**, **Hibernated**, **Removed**.
`Ready` remains an alias for Active and the compatibility default. Pending/error
describes an unfinished transition, not a fourth state. Hibernation deallocates
VM hardware while preserving VM definitions, system-assigned identities, disks
and NICs. Deleting VM definitions would add reconstruction/identity risk without
further pay-as-you-go VM compute savings; this is not Azure RAM hibernation.
See [VM billing states](https://learn.microsoft.com/azure/virtual-machines/states-billing)
and [managed identity lifecycle](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview).

```powershell
$target = @{ SubscriptionId = '<SUB>'; TenantId = '<TENANT>'; SkinPath = '<PRIVATE_SKIN_PATH>' }
.\scripts\Test-Prerequisites.ps1 @target
.\scripts\Deploy-ArcDemo.ps1 @target -AdminEmail <EMAIL> -WhatIf
.\scripts\Test-ArcDemoReadiness.ps1 @target -DesiredState Ready -OutputFormat Json

# Park: deallocates compute, keeps disks and data.
.\scripts\Hibernate-ArcDemo.ps1 @target -WhatIf
.\scripts\Hibernate-ArcDemo.ps1 @target
.\scripts\Test-ArcDemoReadiness.ps1 @target -DesiredState Hibernated
.\scripts\Activate-ArcDemo.ps1 @target -WhatIf
.\scripts\Activate-ArcDemo.ps1 @target

# Remove: deletes both resource groups; preview with -WhatIf first.
.\scripts\Remove-ArcDemo.ps1 @target -WhatIf
.\scripts\Remove-ArcDemo.ps1 @target
.\scripts\Test-ArcDemoReadiness.ps1 @target -DesiredState Removed -OutputFormat Json
```

**Deployment** preflight is **read-only**: tooling, explicit context, effective inherited/group
Owner (or Contributor + User Access Administrator), and needed provider
registrations. Supplying a deployer principal ID does not bypass RBAC checks.
Missing registrations are reported, not fixed: register them separately. Baseline
providers include KeyVault, DevTestLab and Consumption. Optional Container Apps
requires Microsoft.App and the `containerapp` CLI extension; AKS additionally needs
ContainerService, ManagedIdentity, Resources, Storage and ContainerInstance for its
deployment script. A nested SQL parent (security type `Standard`) also needs the
subscription feature `Microsoft.Compute/UseStandardSecurityType`, which you register
once ([nested-sql-demo.md](nested-sql-demo.md#prepare-the-parent)).
`Test-Prerequisites.ps1 @target`, Deploy and the build wrapper's
P0 all read the same set for the skin's workload toggles.
The retired mixed SQL path no longer requests AzureArcData registration;
optional real SQL preparation does not enable Arc SQL.
The genuine nested guest uses its separate explicit extension helper.

Parking/waking/removal does **not** invoke that deployment Graph/Owner/provider/
capacity gate. Use the normal explicit context, retained workload inventory and
`-WhatIf` path; a genuine ARM authorization failure still stops the operation.
Before wake writes, exact subnet/NAT/PIP GETs refuse a foreign NAT,
another attached subnet/public IP/prefix, or a PIP bound to another resource.
Hibernate parks compute first; these same conflicts skip only network cleanup,
with a loud warning and retained-network cost diagnostics.
These narrow sharing guards cover network sharing only; RBAC permissions still
apply. Do not compare whole resource-group counts or historical generic
extension indexes as a lifecycle gate. Optional identity removal checks directory
ownership/access before any removal writes, including on its preview.

Deployment checks the requested VM SKU's location restrictions and regional/family
vCPU quotas. These checks **do not prove spare physical capacity**; even ARM
validation/what-if cannot guarantee allocation. Do not create throwaway probes in
an arbitrary subscription. AKS node capacity is additional to backing VMs.

`-WhatIf` does not register providers, switch the CLI default subscription, reset
credentials, repair resources or run guest commands. Deployment preview uses
ARM what-if and a temporary parameter file removed in `finally`.

Deploy reads the live Defender for Servers plan (`az security pricing show`,
read-only, also during `-WhatIf`) and enables Plan 2 only when its tier is not
`Standard`: a fresh subscription, or one where `Remove-ArcDemo -DisableDefender`
set the plan to Free. An enabled plan keeps its tier, subPlan and extensions
(for example AgentlessVmScanning) because the template is not applied to it: the
module declares no `extensions`, so ARM what-if would report
`Delete properties.extensions`. A plan other than P2 is preserved, not upgraded;
an unreadable or unknown tier stops Deploy.

## Nested SQL guest

The [nested SQL runbook](nested-sql-demo.md) is the single build/park/wake/remove
path. The proven scratch build is primary; Jumpstart is a manual alternative.
The base Arc/Monitor deployment still does not install SQL.

Define the guest once in the private skin:

```json
"nestedSqlGuest": {
  "enabled": true,
  "parentVmName": "win-sql-02",
  "guestVmName": "sql-guest",
  "arcMachineName": "sql-guest"
}
```

These are names in the demo resource groups, not credentials or arbitrary
resource IDs. Defaults leave it disabled. Use the same skin for every operation.
The exact configured Windows parent may already be in the retained fleet (the default
fleet's `win-sql-02`, which Deploy then creates as `Standard_D4s_v5` with a 128 GiB data
disk and security type `Standard`, see [cost.md](cost.md#qualified-retail-comparison));
a separately created parent is selected only from that same infra group.

Activate restores outbound networking, starts the parent, starts an Off/Saved
Hyper-V guest without restarting a Running guest, then waits for the guest's
Arc connection. Hibernate uses normal `Stop-VM` (not `-Shutdown`, `-TurnOff` or
forced power-off), waits for Off, then deallocates compute. If guest shutdown
fails, it warns and still attempts spend-reducing parking of all targeted compute;
that is not a guest-data-consistency claim. Remove makes one bounded (ten-minute)
graceful stop of a running guest; if that stop fails it warns and continues,
because the parent, its disks and the guest are deleted with the group anyway. It
skips the stop when the guest never became an Arc machine (an unfinished build)
and treats a parent without the Hyper-V role or a guest that does not exist as
nothing to stop. A
parked parent needs no guest boot for removal. Definitions/disks/credentials are
retained on park/wake, not recreated.

Readiness remains read-only. For Active it checks the configured Arc guest's
connection; actual SQL query and extension startup are checked by
`Test-NestedSqlDemoGuest.ps1`. SQL extension startup can lag after a cold wake.
No automatic enrollment, SQL reinstall or credential rotation is a wake step.

## Inventory and retry semantics

### Retained base fleet

Successful subscription deployment outputs are retained as the lifecycle
manifest, filtered by the exact Arc resource group. A later optional-workload-only
deployment can have an empty `vmFleet`; it does **not** delete the earlier Arc
fleet. Lifecycle discovery uses the latest nonempty Arc fleet and retained
native-VM/Container-App IDs. Older AKS manifests are supplemented only by tagged
clusters in the demo infra group. Preserve deployment history while the estate
exists. A manifest whose infra group no longer exists (after `Remove-ArcDemo`) is
stale: `Deploy-ArcDemo.ps1` ignores it, builds a fresh Key Vault and writes a new
manifest. While the infra group exists the vault guard is unchanged: the manifest
vault must be in it, or Deploy refuses. Optional `Remove-ArcDemo.ps1
-PruneDeploymentHistory` deletes this demo's own finished `arc-demo-<timestamp>`
records for the removed Arc group once removal is verified, so a same-prefix rebuild
starts from a clean list (otherwise lifecycle discovery also reads the old
estate's native-VM, Container App and AKS IDs); policy, SRE and other deployment
records are never touched. Missing manifests,
unknown VMs, OS mismatch and IDs outside the demo infra group are errors, not
reasons to guess which VMs to start or delete. For an unused alternative parent,
the private skin can explicitly set `operations.keepParkedVmNames` to an array
of names in this infra group. Each must already be deallocated and outside the
active retained fleet/configured nested parent. Activate never starts or invokes
guests on these VMs; Active readiness verifies they remain deallocated. Other
unknown VMs still fail closed. A listed name must keep existing: once that VM is
deleted, Activate and readiness stop with `Explicit keep-parked VM <name> must
exist … and be deallocated`, so remove deleted VMs from `operations.keepParkedVmNames`
in the same change. Hibernate instead discovers all
VMs, AKS and Container Apps in the explicitly targeted `rg-<prefix>-infra`;
manifest/OS/skin drift is a warning, not a reason to leave that compute running.
No workload ID outside that exact subscription/group is accepted. If the skin
cannot be read, pass `-NamePrefix` explicitly; do not guess a
target from a broken skin. Preserve manifests for the stricter later activation.

Actual `storageProfile.osDisk.osType` is checked against the manifest. Azure-native
Windows VMs are never treated as Linux or expected to have an Arc identity.
Monitor-supported hosts, Windows VM Insights hosts, and Arc patch-assessment
targets are distinct sets. Heartbeat compares `_ResourceId`, not computer counts.

Activation restores NAT before starting VMs, starts stopped AKS, and reactivates
the latest Container App revision only if none is active. Already-running/connected
machines are never restarted, but **every activation verifies the hosts**, including
on a retry after partial failure, in one shared wait with a single global deadline
(`-GuestCheckMinutes`, default 12). Each poll costs the same however many hosts
there are: one `az connectedmachine list`, **one** Log Analytics query returning
`max(TimeGenerated)` per `_ResourceId` from `Heartbeat`, and one parallel,
time-boxed ARM read of extension provisioning states. A host passes when its VM is
running, its Arc identity is `Connected` and, for a monitored host, a Heartbeat was
generated **after the VM start time**: the moment activation requested the start, or
the start of the attempt for a host that was already running or starting. A host
with no Heartbeat at the deadline is `pending` for that host only. A VM that is no
longer running, an Arc identity that never connects, or no Heartbeat together with
a `Failed` AMA extension fails. Observed wake: 11 min 55 s (5 November 2026, Linux hosts
ready about 3 minutes after their start, Windows hosts about 7.5) and 14 min 54 s
(2 November); expect about 12-15 minutes (VM start 3-4, NAT 1-2, Windows Heartbeat up
to about 9) rather than 30-45+.

The Arc `status` is the slowest signal to move, in both directions. After a
deallocation the Arc machines kept reading `Connected` for 11-16 minutes (observed;
Microsoft documents a heartbeat every five minutes and `Disconnected` "within 15 to 30
minutes" of the last one, see [agent status](https://learn.microsoft.com/azure/azure-arc/servers/overview#agent-status)),
so an Arc row that reads `Connected` just after a start proves nothing. Trust the
Heartbeat that was generated after the start; it is the condition that decides the wait.
After a park longer than that, the next wake meets machines that read `Disconnected`.
Learn says the status changes back to `Connected` on the next heartbeat; this lab has
not yet shown that reverse transition (see [validation boundaries](#validation-boundaries)).

**No Run Command is used for host checks by default.** Run Command queues behind VM
extension updates (Defender MDE, AMA, Change Tracking), so N blocked Linux VMs used
to cost up to N x 15 minutes and then fail activation although Heartbeats were
fresh. Extension provisioning state (AMA, Change Tracking, MDE) is only a
time-boxed **soft warning**, printed as
`extension <name> Updating for at least <n> min (not a gate)`, recorded in the
per-host evidence and shown by readiness as
non-required `extension/*` rows. The required `heartbeat/*` rows stay the authority.
`-GuestChecks WhenStalled` runs the guest health script only on a host with no
Heartbeat after `-StallMinutes` (default 9), and only when its VM agent is Ready and
no VM extension operation is in flight (it would queue behind it).
`-GuestChecks Always` runs it on every host. Both are asynchronous jobs that share the global
deadline, and neither restarts anything unless `-RepairStalledAgents` is also
supplied. The script checks the Windows Arc `himds` service and, for monitored hosts,
the `MonAgentCore` process with a ten-minute startup wait; it does not assume the
Windows client/MSI `AzureMonitorAgent` service exists or restart the extension
host. Linux checks each required service individually. A guest check that is still
queued at the deadline leaves the host pending, not failed; missing/stopped
required services and command failures still fail.
See [Windows Arc AMA troubleshooting](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-troubleshoot-windows-arc).

The nested SQL guest start keeps its Run Command, but it is submitted as soon as the
parent VM is running, runs concurrently with the host checks and has its own
five-minute budget. If it does not finish in time, the wait relies on the guest's
Arc connection (a warning is recorded). A failed start command, or a guest Arc
machine that is not `Connected` at the deadline, fails activation.

Unless skipped, activation submits assessments only for Arc hosts started/waking
on the attempt. Already-active retries still verify guests but **do not resubmit**
assessments. Use `-AssessPatches` to explicitly request all-host assessment work,
including retrying a failed assessment phase after compute is already running.
It conflicts with `-SkipPatchAssessment`; native VMs are not Arc assessment
targets. The activation result records `not-required` when no hosts need default
submission. This is not proof of earlier assessment success or freshness.
Submission is **not** assessment completion. The first assessment also makes the Update
Manager identity add one `WindowsOsUpdateExtension` or `LinuxOsUpdateExtension` Arc
extension per host (eight on the eight-host lab). They are not drift: an inventory count
taken before and after the first wake rises by that many. `-SkipPatchAssessment` opts out;
if Azure returns `OperationConflict` because an assess/patch operation is already
running, activation warns and records `already-in-progress` in its per-host
assessment output. It does not retry, cancel or claim completion. Other errors,
including denied or missing resources, still fail activation.
`-SkipValidate` opts out of final readiness, so a run that used it has not
validated the demo. Activation never changes workload fault flags.

Use `-ResultPath <PRIVATE_EXISTING_DIRECTORY>\activation-attempt.json` to retain
schema-versioned per-host `guestChecks` (`method`, `startedAtUtc`, `lastHeartbeatUtc`,
`arcStatus`, `extensionStates`, warnings and any restarted service names), the nested
guest outcome, assessment submission states, final readiness and failure information
outside git. Use a new
file per attempt. This report does not include arbitrary guest output or scripts.
After the host wait, a single full readiness snapshot is taken.
If only required `heartbeat/*` checks are pending, activation exits 0 but records
`status:pending`, `readiness:pending` and exact readiness rows, with a re-check
message; a host left pending by the wait also records `status:pending` even with
`-SkipValidate`. Any other required pending/failed check remains a failed activation.
Poll the read-only readiness command until it passes before you present or check
the dependent SRE layer; activation exit 0 alone does not prove telemetry has
arrived.
Completion must come from stdout with no failed/Error-level result; a marker in
stderr alone is not success. `-WhatIf` neither invokes guests nor writes this report;
it lists what a real run would do from the inventory and network it read (the NAT
gateway and public IP it would create and tag, each VM with what happens to it, the
nested guest, AKS, the Container App revisions and the shared wait). The tags are the
lab's own (owner, purpose, costcenter, env and the skin's `tags`): Bicep stops declaring
the NAT gateway and public IP once they exist, so Activate writes them again on the pair
it recreates and checks them on every run. A tagging failure warns and never stops the
wake, and parity reports an untagged pair.

Fresh deployment creates NAT/PIP before backing compute/extension provisioning;
it does not rely on implicit default outbound. Redeployment preserves an existing
gateway. Hibernation still removes the same named resources; activation recreates
them. See the [documented NAT/subnet resource model](https://learn.microsoft.com/azure/nat-gateway/manage-nat-gateway#create-a-nat-gateway-and-associate-it-with-an-existing-subnet).

Hibernation requires every discovered demo infra-RG VM to be **deallocated**, not merely stopped
or missing from a running-count query. AKS must report `Stopped` and provisioning
`Succeeded` before NAT removal. All active Container App revisions are deactivated;
setting minimum replicas to zero alone does not prevent HTTP scale-out.
Fault flags, storage, DCRAs and guest configuration are preserved.
Retries inspect current state and do not repeat completed state transitions.
In-flight VM deallocation/start and AKS stop/start are waited for, not resubmitted.
Activation waits for AKS Running even with `-SkipValidate`. Individual compute failures warn and do not prevent attempts on other VMs,
clusters, apps or revisions. Final compute verification remains mandatory.
Failures leave completed
parking steps intact: do not wake/redeploy to undo a partial stop. Retry the same
target to finish remaining known transitions (for example a failed PIP deletion).
Network sharing is inspected again before removal after compute has stopped.

Hibernate prints a time-stamped line for each phase, so its seven minutes are not
silent. Its `-WhatIf` lists what each workload would do (each VM with its power state,
the nested guest, AKS, the Container App revisions, the NAT gateway and public IP)
instead of one generic sentence; it takes about 80 seconds on eight VMs because the
full inventory is read first. `-ResultPath <PRIVATE_EXISTING_DIRECTORY>\hibernation-attempt.json`
keeps the same evidence Activate's does outside git: the steps with their times, each
VM's power state before parking, the revisions deactivated, the network outcome and the
closing Hibernated readiness rows. The file is written when the run starts and again
when it ends, passed or failed; a folder that does not exist is refused before anything
is parked. A run that is stopped (Ctrl+C) records `status: interrupted`, because steps it
already submitted may still be in progress, and a file that cannot be written at the end only
warns, so it never hides the error the run ended with. The same holds for Activate's file.
Use a new file per attempt.

Hibernated **required** acceptance is VM deallocation, deployed AKS
Stopped/Succeeded and no active Container App revision. Named NAT/PIP absence
is reported as **non-required cost diagnostics**: unsafe binding conflicts or
cleanup failures warn without undoing or failing verified compute parking.
Inspect these rows before claiming network savings; a foreign NAT is never
detached. Retained groups/Arc records/Monitor configuration and telemetry are
not queried by Hibernated readiness. Use Active readiness before the next demo.
Readiness does not repeat strict manifest or skin validation while parked.
Unknown power or denied/malformed required reads still return nonzero, not
verified Hibernated: an unreadable state cannot prove stopped compute.
Actual network inspection/auth errors also remain visible errors, never absence.

No automatic alert/polling pause is introduced: owned alert definitions remain
enabled as before and may incur evaluation/notification costs. Safe restoration
would require preserving exact previous enabled state and reconciling concurrent
changes/companion routing; a generic disable/enable would be unsafe. Evaluate a
separate explicit pause only if measured savings justify that added state.

**Every Hibernate fires the Sev2 missing-heartbeat alert.** The rule
`alert-<prefix>-host-missing-heartbeat` looks for a host whose last Heartbeat is older
than 10 minutes, so it fires about 8-10 minutes after the VMs are deallocated (observed
7.7-9.7 minutes after the VMs read deallocated, 11.5 minutes after the last Heartbeat)
and notifies the one e-mail receiver on the action group. It cleared itself 16-21
minutes after it fired, and after the second Hibernate it did so while every host was
still silent, so a cleared alert is not evidence that the hosts came back (the rule's
15-minute query window probably explains it; that was not tested on a real outage).
Nothing is paused and the rule is not faulty.
A short park fires it during the next Activate too, until the last Windows host's
Heartbeat returns (observed: cleared about 12 minutes after). The nested guest sends no
Heartbeat rows, so the rule never covers it. E-mail delivery was not verified. This is
why the companion SRE agent is parked first and woken last: an agent that is active
during a Hibernate would receive this Sev2 as a live incident. Muting it while parked
(an alert processing rule that suppresses the action group, created by Hibernate and
removed by Activate; see [alert processing rules](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-processing-rules))
is not implemented; whether to add it is your call.

Before parking, keep the target, exact skin/fleet files and their hashes,
prefix/region, deployment-manifest identities and optional revision/fault state
in your [private folder](private-config.md) outside git. Hibernation needs no VM
password or onboarding secret and does not rotate either. Keep the existing Key
Vault and tenant onboarding identity for later deployment or reconciliation.

If the optional SRE layer is attached, finish its fault window and park that layer
first with its own scripts. Then preview and run Arc hibernation. Wake Arc/Monitor
and verify Ready before you resume the dependent SRE layer. Readiness requires no
active Container App revisions while parked; its fault flag remains unchanged. An
intentionally retained fault returns on reactivation, so check it after the wake;
the scripts never reset it.

AKS has additional timing/capacity constraints: allow 15-30 minutes between stop
and start, and do not interleave operations. Stopped state is retained for up to
12 months; standalone pods are not preserved. Storage and other resources remain
billable. See [AKS stop/start](https://learn.microsoft.com/azure/aks/start-stop-cluster)
and [Container App revision management](https://learn.microsoft.com/azure/container-apps/revisions-manage).

Removal waits for both resource groups **and** named subscription policies/budget
to disappear; a rerun skips already-absent objects. The wait is `-TimeoutMinutes`
(default 60, at most 120) and normally takes 25-35 minutes, because a Container Apps
environment stays in `ScheduledForDelete` for about 25. Each change to the list of
objects still present is printed. When the limit passes first, Remove exits 2
(deletion still in progress, nothing retried), skips the prune and Defender steps
that need verified removal, and the same command run again finishes them.
Exit codes are 0 removed and verified, 1 error, 2 still deleting. Optional `-ForceDeleteWorkspace`
first permanently deletes `law-<prefix>` (irreversible, under its own confirmation):
without it the workspace is only soft-deleted for 14 days and re-creating the same
name recovers its old data. `Removed` read-only verification
needs no deployment history, VM inventory or directory lookup. Its mandatory
boundary is those Azure-owned objects, not tenant-wide cleanup. Subscription-wide Defender
pricing is **preserved by default**; only `-DisableDefender` changes it, and this
can affect other workloads. `-KeepDefender` remains a compatibility switch.
`-RemoveOnboardingIdentity` is separately opt-in and refuses ambiguous identities
or identities with assignments outside the Arc group. Soft-deleted Key Vaults and
retained tenant applications are explicit exceptions, not verified absence.
Default removal deliberately retains the tenant onboarding identity; opt-in SP
deletion does not claim application-object deletion. No purge is performed.
Review these exclusions/delayed billing separately; do not promise a zero bill.

### What still happens to a parked estate

Observed on 5-6 November 2026 from read-only reads of an estate that stayed parked for
about three hours. None of it is a lab fault and none of it needs action; it is listed
so you don't chase it in the activity log of a parked lab.

- **Arc status** reads `Disconnected` 11-16 minutes after the stop. Resource Health for a
  parked Arc machine flaps between `Available` and `Unavailable` and disagreed with the
  `status` field for 16-20 minutes, so read `status`, not Resource Health. Hibernated
  readiness has no Arc row, so the delayed flip cannot fail it. The reverse reconnection
  at the next wake is not yet proven.
- **No Defender push** arrives while the VMs are deallocated: three hourly slots passed
  with no event. That says nothing about the push after a wake
  ([below](#linux-vms-and-the-defender-mdelinux-install-lock)).
- **The Sev2 heartbeat alert** fires and clears itself, as described above.
- **Platform patch writes**: a platform update service writes the patch extensions on the
  Arc machines about every 4.5 hours. A write to a parked machine stays `Running` for
  about 31 minutes and then fails with `HCRP400` "The Hybrid Compute machine is not
  connected to Azure."
- **Linux VM extensions** (AMA, Change Tracking, `MDE.Linux`) read ARM `Updating` for at
  least 86 minutes after a Hibernate that cancelled a stuck Defender write. Their effect
  at the next Activate is not known.
- **Activity-log noise**: hourly `upgradeExtensions` `HCRP404` failures on the Linux Arc
  machines, Advisor recommendations for names that are not in the subscription, and
  `Failed` `deployIfNotExists` evaluations of the repo's own `nist-<prefix>` assignment
  after every VM write. See
  [troubleshooting](troubleshooting.md#activity-log-noise-on-an-idle-or-parked-estate)
  and [the policy entry](troubleshooting.md#failed-deployifnotexists-policy-events-follow-every-vm-write).
- **Disk tier**: a governance automation can convert the disks to Standard HDD while the
  estate is parked, and the next Deploy then refuses the tier. See
  [troubleshooting](troubleshooting.md#the-os-disk-tier-changed-by-itself).

### Adding an optional workload to a running estate

The incremental path works: set the workload's flag (`workloads.deployContainerApps`,
`deployAks`, `deployAzureVMs` in the private skin, or the matching `-Deploy...` switch) **in the
same step as the Deploy that creates it**, then run the same Deploy again. It adds only the new
resources (for Container Apps: the environment, the fault app, the restart alert and the Arc-path
MDE extensions); no VM is restarted and no disk, the vault, the subnet, the NAT gateway or the
Defender plan is touched. On an existing estate, do not set the flag earlier: lifecycle commands
and read-only readiness compare the skin with the retained manifest, so with the flag already
`true` and nothing deployed yet, readiness ends with exit 1 and one `readiness/error` row, "Skin
requires deployContainerApps, but no retained workload manifest exists. Reconcile deployment
before lifecycle operations." That is expected, not damage; deploy the workload, then run
readiness.

The whole-demo build is the exception: the SRE half needs the Container App, so the
[setup block](private-config.md#set-up-the-whole-demo) sets the flag before P2 and the first
Deploy creates it. If P2 stops on the environment (`ManagedEnvironmentProvisioningError`, a
transient platform error), rerun the same wrapper command: it resumes P2 and reuses the saved
admin password; don't Remove. Readiness run after a P2 that failed with the flag already `true`
shows the same kind of `readiness/error` row: "No successful deployment manifest for
`rg-<prefix>`..." while no deployment has Succeeded yet, or the "Skin requires" row above when an
earlier one did. Both are expected until a Deploy completes.

Expect these side effects of any Deploy pass, not only this one:

- The Container Apps environment alone takes 17-23 minutes and can sit in `Waiting` for 20 or
  more ([container-app-fault.md](container-app-fault.md#deploy)).
- A VM behind a pending Defender extension operation can hold the deployment for much longer
  ([troubleshooting](troubleshooting.md#a-linux-vm-stays-updating-behind-a-defender-mdelinux-install-lock)).
- The DevTest auto-shutdown schedules are set to the skin's `operations.autoShutdownTime`
  again; Deploy warns first and names any live schedule that differs.
- The machines' `role` and `osTier` tags are checked and written only where they differ,
  merged with any other tag.

## Credentials and partial deployments

Routine redeployment never resets the onboarding SP credential. Existing VMs
reuse `vm-admin-password` from their existing Key Vault; if that secret was never
stored or the vault cannot be read from the workstation, supply the **current**
password as `-AdminPassword` (SecureString) or as the file an earlier run saved
with `-AdminPasswordPath` (below). Do not supply a new password as a convenience:
credential rotation is a separate operation, not part of redeployment. Fresh
deployments generate the password, save it to Key Vault through Azure Resource
Manager and, when `-AdminPasswordPath` is given, to that file first.
For `Deploy-ArcDemo.ps1`, new Arc onboarding runs through
`Initialize-DemoOnboardingIdentity` once the Arc resource group exists. An
existing `sp-<prefix>-onboard` keeps its credentials: they are never read,
reset or changed. Deploy re-grants its `Azure Connected Machine Onboarding` role
at the Arc group (a deleted group takes the old assignment with it), adds a
one-day credential through Graph, uses it only for onboarding and removes it in
`finally`, then checks the original key IDs are unchanged. Without an SP, it is
created with that role as before; the one-year credential that creation adds is used
for that run only and then removed, by its exact key ID and only when it was absent
before the creation and is named `rbac`, so no long-lived credential is left behind.
An estate built by an older Deploy still carries that credential: parity reports it
as `tenant/no-long-lived-credentials`, and deleting it
(`az ad app credential delete --id <appId> --key-id <keyId>`) is your decision;
no script deletes an existing credential.
`-OnboardingSecret` (SecureString) is an optional override for when you
cannot manage the application's credentials; it skips the one-day credential.
Never commit or log either secret.

Deploy selects a retained vault using the saved `keyVaultName` deployment output
and preserves its public-network-access mode. After a fresh build that stopped part
way (no Succeeded manifest yet) it adopts only the vault named by its own Failed or
Canceled `arc-demo-<timestamp>` deployment, never another one, and it refuses to start
while one of its own deployments is still Running. A private-only vault requires the
current password (`-AdminPassword` or the `-AdminPasswordPath` file); Deploy does
not open it for workstation secret reads. A tenant policy can make every new vault
private-only seconds after creation (see
[troubleshooting](troubleshooting.md#the-key-vault-is-private-only-and-az-keyvault-secret-is-refused-forbiddenbyconnection)),
which is why the first save goes through Azure Resource Manager and why the file exists.
**`-AdminPasswordPath`**: the file lives outside the git worktree, in an existing
folder (the build wrapper passes `vm-admin-credential.clixml` in its
[private folder](private-config.md)). A fresh build writes it before any Azure write;
on Windows it is a DPAPI-protected export that only the same user on the same PC can read
(elsewhere PowerShell does not encrypt it). A later run uses it only when
`-AdminPassword` is absent and the vault is not readable or holds no secret; a readable vault
wins, and a fresh build replaces a stale file. It is never printed or logged.
This protects the existing estate, not a nested-build prerequisite. The
[nested build](nested-sql-demo.md) needs no vault and, like Deploy, no supplied
onboarding secret: it uses the same one-day credential flow.

Mandatory compute/Arc waits throw on timeout; inspection errors terminate. Native CLI
failures terminate; authentication/authorization errors are never interpreted as
resource absence. The one retried write is the first Key Vault save of the generated
password: it goes through Azure Resource Manager (no data-plane role has to propagate) and
retries only throttling, 5xx and connection errors, with a bounded backoff; any other
error stops at once.
Extension jobs must complete successfully; guest commands need
an exact completion marker as well as a nonfailed provisioning result. Only the
activation AMA wait permits the explicit `ARC_DEMO_PENDING` stdout marker;
other guest operations cannot use it to bypass completion. Temporary
credential-bearing files and jobs are removed even after failure. Deploy submits the
Bicep deployment with `--no-wait` and polls it, so the parameters file (which holds the
admin password in plain text in your temp folder) is deleted as soon as Azure accepts
the request, seconds after it is written, not after the whole build.

Routine deployment preserves an existing Container App's `SIMULATE_CRASH` value
and does not re-bootstrap the sample workload on an existing AKS cluster.
Repairing/replacing that sample is an explicit scenario operation, not an
incidental infrastructure rerun. A retained intentional fault can therefore make
Ready checks pending; the scripts leave it in place.

## Read-only readiness JSON v1

```powershell
.\scripts\Test-ArcDemoReadiness.ps1 @target `
  -DesiredState Ready -OutputFormat Json -TimeoutSeconds 600
$LASTEXITCODE
```

`-DesiredState` is `Active`, `Ready` (compatible alias/default), `Hibernated` or
`Removed`; `-OutputFormat` is `Json` or `Table`. The supplied state name is echoed.
Default timeout is zero (one snapshot); 0-1800 seconds bounds eventual-consistency
retries (Deploy's final check waits up to 1200 for Windows Heartbeats). Individual CLI reads and service response times still contribute to total
wall time. A hard failure stops retries. There is no fault induction or repair.

One JSON object is written to stdout:

```json
{
  "schemaVersion": 1,
  "workload": "arc-demo",
  "checkedAtUtc": "<UTC ISO-8601>",
  "subscriptionId": "<runtime value>",
  "tenantId": "<runtime value>",
  "resourceGroups": ["rg-<prefix>", "rg-<prefix>-infra"],
  "desiredState": "Ready",
  "status": "pass",
  "checks": [{
    "id": "<stable check identifier>",
    "resourceId": "<exact ARM ID>",
    "required": true,
    "expected": "<expected state>",
    "observed": "<observed state>",
    "status": "pass",
    "message": ""
  }]
}
```

Check statuses: `pass`, `fail`, `pending`, `skipped`. Exit codes: **0** all required
checks pass; **1** required failure or inspection/configuration error; **2** required
eventual-consistency checks still pending at the deadline. Consumers correlate
`resourceId`, not display names or counts. Preserve raw JSON as dated evidence,
outside committed source because it contains live environment identifiers:
`-OutputPath <file>` writes that same JSON to a file (creating its folder, whatever
`-OutputFormat` shows) and the exit code is unchanged, so no separate capture is needed.

Checks cover retained groups, core resources/workbook presence, exact VM power,
Arc connection, the `role` and `osTier` tags on every Arc machine (required `tags/*`
rows, compared with the deployment manifest), recent Heartbeat by expected ARM ID
(its `observed` text carries the time of the latest Heartbeat and its age), the VM's
ARM provisioning state (soft `provisioning/*` rows) and supported extension
provisioning (soft, non-required `extension/*` diagnostics), DCRA identities, NAT
attachment/presence, AKS power/provisioning and
active Container App revision health. `RunningAtMinScale`/`RunningAtMaxScale` are
valid healthy revision states. Hibernated checks only compute state and named
NAT/PIP cost diagnostics, without inspecting retained monitoring.
Removed checks group/policy/budget absence and emits non-required skipped rows
for retained tenant/shared/soft-delete exceptions. SchemaVersion 1 and existing
0/1/2 exit meanings are unchanged: consumers must honor each row's `required`
flag, not fail merely because any diagnostic row is red.
Extension rows are `required:false`: ARM provisioning state `Updating` can persist
for an hour or more behind an outstanding Defender MDE operation while Heartbeats
are fresh, so a row can read `pending` or `fail` without changing the overall status,
and the command prints one warning. The message carries the state, how long the
host's Arc identity has been connected (the ARM extension model has no timestamp)
and, after 30 minutes, a pointer to [troubleshooting](troubleshooting.md#linux-arm-updating-while-monitoring-guest-handlers-are-healthy).
A `Failed` AMA extension with no recent Heartbeat makes the **required**
`heartbeat/*` row `fail` rather than pending: a failed agent is not telemetry lag.
This is **infrastructure/monitor readiness**, not proof of every guest workload,
Kubernetes pod, policy compliance result, CT inventory cycle, or completed patch
assessment or Defender sensor/AV/EDR health. It does not see the SQL engine, the orders
workload, the SQL lock-timeout alert, the nested guest's Arc SQL instance (`nested/arc` is
the Arc connection only) or the content of most workbooks, and no row compares the Arc
roster that the capacity and optimisation workbooks recorded at their last publish
with the machines that exist now. The build wrapper's P5, P6 and P11 cover parts of that;
a `pass` here is not "demo ready". Demonstrate those separately; never
manufacture fault data to pass.

## Linux monitoring and support stance

In this Azure-VM-backed `MSFT_ARC_TEST` lab, AMA and Linux Change Tracking use the
**Azure VM extension path**, while DCRAs remain on the **Arc machine ID**. Windows
uses Arc extensions. Both VM and Arc CT paths are documented, but ordinary Arc
support is not evidence that this lab's failing guest-extension stack works.
Read-only inspection found stuck Linux Arc extensions and missing CT; the VM-path
CT reconciliation produced guest provisioning success and CT records for
all three Linux hosts without restarts. Do not delete stuck Arc extensions or
change paths incidentally. See the [CT support matrix and CLI examples](https://learn.microsoft.com/azure/azure-change-tracking-inventory/change-tracking-inventory-support-matrix).

Linux VM Insights/Dependency Agent map remains disabled. Linux onboarding gives the
Arc agent daemons (`himdsd`, `extd`, `gcad`) a persistent `MSFT_ARC_TEST=true`
systemd drop-in so the extension manager does not restart-loop after a wake; hosts
onboarded by an older Deploy do not have it (limits and one-off fix in
[troubleshooting](troubleshooting.md#linux-arc-extensions-and-assessments-stay-creating-after-every-wake)).
Linux memory and disk
telemetry comes from the four Linux AMA counters in the core DCR (table `Perf`),
not from VM Insights; see the [workbook reference](operational-workbooks.md#linux-memory-and-disk-counters).
The optional
[real SQL workload](sql-engine-workload.md) is separate from Arc SQL: no SQL Server
enabled by Azure Arc/BPA validation is claimed. Hibernate/Activate retain its
engine/database and startup configuration without an implicit install/reset.
Verify real SQL queries separately after wake; Arc readiness does not establish
optional database/worker health. A stopped/disabled worker remains disabled.

### Linux Defender is a separate diagnostic surface

Guest diagnostics on the three Linux hosts found installed sensors
reporting `healthy=true`, `licensed=true`, no direct health issues and an active
service, but `passive_mode_enabled=true`, `real_time_protection_enabled=false`
and `engine_load_status="Engine not loaded"`. MDE extension models converged to
Succeeded/onboarding Success after startup without a manual MDE repair.
Two extension payloads still recorded event-provider issues that differed from
the newer direct sensor health. Do not label this active-antivirus or complete
EDR/event-delivery validation, or change policy to make the story greener.

The earlier timeout's underlying cause is not established. Keep timestamped ARM,
guest health and existing log evidence separate. No reinstall/retry/removal,
service restart, VM restart or AV-mode change follows from diagnosis alone.

### Linux VMs and the Defender MDE.Linux install lock

A defect in the vendor's MDE.Linux handler can leave a Linux VM `Updating` for about
90 minutes while the guest is healthy: every real `enable` leaves a 36-minute orphan
install lock, and a Defender push inside that window is never completed. The
[troubleshooting entry](troubleshooting.md#a-linux-vm-stays-updating-behind-a-defender-mdelinux-install-lock)
has the cause and the recovery. For the lifecycle this means:

- Every boot of a Linux VM runs a real `enable`, so a Defender push within 36 minutes
  after an Activate can leave that VM `Updating`. With the observed hourly push and
  independent timing that is roughly three in five VMs (derived from the 36-of-60-minute
  window, not measured; the push cadence did not stay hourly after one recovery, so treat
  it as an upper bound). It happened to all three Linux VMs after the Activate of 5 November
  2026: a push 26 minutes after they finished starting left them `Updating` with
  Heartbeats fresh, and the next Hibernate cancelled it 16.5 minutes later (left alone the
  platform would have timed the write out about 91 minutes after it began). A Run Command,
  a tag edit or a Deploy re-PUT during the window adds another `enable` and lengthens it, so
  do none of them on those VMs while they are `Updating`: wait, or Hibernate, and never
  redeploy. Activation is unaffected: it passes a host on VM running, Arc
  `Connected` and a fresh Heartbeat, and shows the extension state as a soft warning.
  Nothing pushes to a deallocated estate (three hourly slots passed with no event while it was
  parked), and one slot after a wake does not show that the cadence after a wake is hourly.
- Readiness reports the VM's ARM provisioning state and `MDE.Linux` state as non-required
  `provisioning/*` and `extension/*` rows with a pointer to the entry; they never gate.
- Hibernate on `Updating` Linux VMs is proven (5 November 2026). With all three Linux VMs
  `Updating` behind a Defender write that had been open for about 14 minutes, every
  deallocation was accepted at once, with no 409 and no queueing; the stuck writes show
  `Canceled` in the activity log 11-15 seconds before the VMs first read deallocated, and the
  run exited 0 in 416.4 seconds. Hibernate submits every deallocation without waiting, then
  waits up to 20 minutes for each VM to read deallocated; a VM that is still not deallocated
  fails the run with an error (never "verified stopped") and keeps the progress made, and a
  rerun after the VM settles finishes the job. The DevTest auto-shutdown and a governance
  deallocation against `Updating` VMs were not exercised: the estate was already deallocated
  by then.
- Deploy warns before it submits when a VM is already `Updating`, then polls with progress.
  A tag edit or a re-PUT of a Linux VM is a write that can seed the stall, so Deploy skips
  the Arc tag write when the tags already match.

## Validation boundaries

Mocked Pester tests, script parsing, PSScriptAnalyzer, Bicep compile and live
read-only readiness are separate evidence. Historical operational evidence does
not prove current health or validate new code: keep it privately, and keep the
working-path timings in the [nested SQL runbook](nested-sql-demo.md).
Keep script completion, independent readiness, fresh telemetry and assessment
completion separate; preserve per-host attempt results outside git.

A fresh deployment, double-deploy idempotency, AKS park/start and delete/recreate
remain separate validation exercises. Operational hibernation only proves the
parked state actually observed, not future activation or fresh deployment.
Run full or destructive smoke cycles only in a disposable lab, never against a
demo you are using.

An earlier retained-estate wake on 2 November 2026 used the old Run Command host
checks; all eight passed, but independent readiness still reported six Linux
extension models `Updating`. See the [earlier dated evidence](nested-sql-demo.md).
The shared Heartbeat wait replaced those host checks afterwards.

### Default shared-wait park/wake proof: 2 November 2026

One cycle ran from a clean checkout of merged main `3a70e96`, including the
shared-wait, best-effort parking and nested-parent lifecycle changes.
Default Hibernate ran from 03:00:50 to 03:09:25 UTC: **8 minutes 35.2 seconds**.
Direct post-park reads verified the eight fleet VMs (plus a since-deleted
prototype VM) deallocated, the named NAT gateway and public IP absent, and all 35
retained Container App revisions inactive and `Stopped`. For independent revision
reads, use `az containerapp revision list --all`: the default list hides inactive
revisions.

Default Activate ran from 03:13:25 to 03:28:19 UTC: **14 minutes 54.1 seconds**
wall-clock, exit 0 and result `pass`. No skip flags, host-check Run Commands, explicit
service restarts or repair fallback were used. The shared 12-minute host deadline
is not an end-to-end wake-time promise: preflight, network restoration, compute
starts and final readiness also contribute to wall-clock time.

All eight monitored hosts passed using `arm+heartbeat`; the saved results recorded
Arc `Connected`, empty `restartedServices` and these post-start Heartbeats.
Times below are UTC on 2 November, not a current-health snapshot.

| Host | Method | lastHeartbeatUtc |
| --- | --- | --- |
| win-sql-01 | arm+heartbeat | 03:22:31.5745042 |
| win-sql-02 | arm+heartbeat | 03:23:13.0873741 |
| win-app-01 | arm+heartbeat | 03:22:48.6951573 |
| win-app-02 | arm+heartbeat | 03:22:51.0222153 |
| win-app-03 | arm+heartbeat | 03:22:54.3905789 |
| lnx-app-01 | arm+heartbeat | 03:18:38.4845995 |
| lnx-app-02 | arm+heartbeat | 03:17:04.7261035 |
| lnx-app-03 | arm+heartbeat | 03:18:47.4256979 |

The nested guest's separate parent Run Command ran concurrently from
03:16:57.544 to 03:18:09.964 UTC, about **72.42 seconds**, within its five-minute
budget. Its start result and Arc connection passed. Five Windows patch assessments
were submitted; the three Linux submissions reported `already-in-progress`
conflicts, without retry or cancellation. Submission is not completion.

Independent read-only Active readiness passed at 03:38:50 UTC with no required
non-pass rows. Six Linux AMA/Change Tracking VM-extension models still reported
`Updating` as non-required warnings. The activation REST snapshots had reported
`Succeeded` for the same extension paths; the cause of the differing readbacks
was not established. This is not proof of extension completion. Required
Heartbeats passed, and no extension or sensor repair was attempted.

This proves one short retained-estate park/wake, including fresh post-start
Heartbeats without the old explicit service restarts. Arc records still read
`Connected` before wake while their backing VMs were parked, so an observed
`Disconnected` to `Connected` transition, long-park reconnection and guest service
health were not proven. The
[5-6 November proof](#park-wake-and-park-again-5-6-november-2026) later showed the
`Disconnected` half; the reconnection is still open. Fresh deployment, double-deploy
idempotency, AKS, assessment completion, full removal and rebuild remain outside this
proof; drift, denial and partial-failure paths remain mocked.

The best-effort parking and shared-wait changes have local coverage for
missing manifests, unlisted VMs, OS/skin drift, foreign NAT, partial deallocation,
denied/unknown power, one global deadline with per-host pending/fail outcomes, soft
extension warnings, opt-in Run Command and its script's five-minute AMA start and
ten-minute pending evidence, and
telemetry-only pending versus real service/readiness failures. Native-process
stderr and explicit-null JSON regressions remain. Mocks cannot prove Azure
allocation, guest boot timing, RunCommand delivery/truncation, eventual ARM
consistency or ingestion latency; a separate disposable smoke cycle would show
those (see [cost.md](cost.md#proposed-disposable-smoke-cycle-not-executed)).

### Park, wake and park again: 5-6 November 2026

One cycle on a rebuilt eight-host estate (nine Arc machines with the nested guest)
ran Hibernate, Activate and Hibernate again. Durations are wall-clock from the
scripts' own timing, not promises. The 2 November figures above came from a
different estate.

| Phase | Result | Duration | 2 November figure |
| --- | --- | --- | --- |
| Hibernate `-WhatIf`, twice | exit 0; one generic line then (a per-workload plan now) | 75.6 s and 81.6 s | n/a |
| Hibernate | exit 0, Hibernated status pass | 435.6 s (7 min 16 s) | 8 min 35.2 s |
| Independent Hibernated readiness | pass, 12 of 12 rows | 0.9 min | n/a |
| Activate | exit 0, result pass, readiness pass | 715.4 s (11 min 55 s) | 14 min 54.1 s |
| Independent Active readiness | pass, 80 rows, no required or soft row failing | 2.7 min | n/a |
| SQL engine status, nested guest test, Arc SQL inventory | pass | 76.7 s, 36.8 s, 13 s | n/a |
| Live parity | pass, 57 of 57 checks, with the [Graph workaround](troubleshooting.md#microsoft-graph-calls-fail-with-a-continuous-access-evaluation-challenge) | 151 s | n/a |
| Hibernate again, three Linux VMs `Updating` | exit 0, Hibernated status pass | 416.4 s (6 min 56 s) | n/a |
| Independent Hibernated readiness | pass, 12 of 12 rows | 0.8 min | n/a |

What this proves, for this estate and these dates:

- All eight deallocations were accepted together with no 409 or queueing; Windows VMs read
  deallocated within about a minute and Linux VMs within about three.
- Hibernate preserved the DevTest schedules, the Defender plan and extensions, the fault
  flag, the disks, the vault, the Arc identities and extensions and the alert rules.
- Everything came back after Activate with no manual action: the SQL engine and orders
  worker, the nested guest's Arc agent and SQL extension, the Arc SQL inventory (four system
  databases online) and the Container App revision.
- Hibernate with the three Linux VMs `Updating` from a Defender push is accepted at once
  with no 409 and cancels the stuck writes. The post-Activate Defender stall is real (a push
  26 minutes after boot stalled all three Linux VMs) and cleared on that Hibernate.
- The Arc machines read `Disconnected` 11-16 minutes after the stop and stayed so, and
  nothing pushed to the estate while it was deallocated
  ([what still happens to a parked estate](#what-still-happens-to-a-parked-estate)).

Still not proven:

- The reverse transition. The Activate in this cycle began about three minutes after the
  first Hibernate ended, before any machine read `Disconnected`, and the machines were not
  woken after the second park. Only an Activate after a long park shows whether the Arc
  machines reconnect without help; the wake wait's Arc `Connected` and Heartbeat-after-start
  conditions decide it.
- Whether the ARM `Updating` state that the Linux VM extensions kept after the deallocate
  matters at the next Activate, and whether a platform patch write that is still pending
  when an Activate starts overlaps the boot-time `MDE.Linux` lock.
- Delivery of the heartbeat alert e-mail.
