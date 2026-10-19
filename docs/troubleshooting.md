# Troubleshooting

## Directory CLI rejects --subscription

`az ad` operations are tenant-scoped; commands such as `az ad sp show` do not
accept `--subscription`. The checked adapter does not append that argument to
directory commands. Before any directory read/write it verifies the CLI's actual
default tenant matches the explicit requested tenant, and stops on mismatch.
It never silently switches defaults to make an identity operation succeed.

## Multiline Azure CLI arguments are truncated on Windows

**Symptom** — A multiline Resource Graph query returns unfiltered resources, or
an inline guest script does not execute its later lines.

**Cause** — Passing embedded newlines through the Windows `az.cmd` launcher can
truncate the native argument at its first line. A successful CLI exit is not proof
that the intended query/script was transported.

**Fix** — For REST queries, send the complete query in a JSON request body. For
simple KQL without line comments, flatten line breaks before invoking the CLI and
verify the result shape. Guest commands use the documented
[`--scripts @script.ps1` file form](https://learn.microsoft.com/azure/virtual-machines/windows/run-command#using-run-commands).
`Invoke-DemoGuestCommand` retains its temporary UTF-8 script until the bounded job
finishes and removes it on success/failure. Do not print credential-bearing scripts.

## Linux ARM Updating while monitoring guest handlers are healthy

Inspect ARM model state, VM guest instance view, recent activity and exact-ID
telemetry separately. An outstanding MDE.Linux operation can coincide with AMA
and Change Tracking reporting ARM Updating even when their guest handlers report
Succeeded and data continues to arrive. Readiness must remain pending, not be
forced green. A missing MDE status file is not proof of working endpoint protection.
Preserve healthy AMA/CT and DCRAs; agree a targeted recovery before retrying MDE or
restarting anything. No reinstall/restart is part of read-only rehearsal preflight.

> Every failure mode I've personally hit during build or operation, with a verified fix.
> If you hit something not listed here, please open an issue (or PR a fix in this file).

## Activation waits forever or reports success with missing hosts

Old lifecycle scripts compared counts, inferred Windows from `win-*`, ignored
timeout results and expected native Azure VMs to have Arc records. They could
also use only the newest empty fleet after an optional-workload-only deployment.
The maintained scripts require explicit subscription/tenant, retain per-workload
manifests, use actual VM OS metadata and compare exact IDs. Run read-only
`Test-ArcDemoReadiness.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -OutputFormat Json`.
Resolve its failed checks; do not add unrelated hosts to satisfy a count.
Do not delete subscription deployment history: missing/ambiguous inventory is an
error requiring operator reconciliation, not a silent "no VMs" success.

## Linux Change Tracking missing despite healthy AMA

The previous deploy implementation installed CT via Arc while AGENTS required
the Azure VM path for this lab's unreliable Linux guest-extension stack.
Ordinary Arc CT support does not validate that stack on an Arc-enabled Azure VM.
The maintained path uses `Microsoft.Azure.ChangeTrackingAndInventory` /
`ChangeTracking-Linux` as a **VM extension**, retaining existing AMA and **Arc-ID**
DCR associations. Approved installation on the three Linux lab hosts verified
handler 2.42.0.0 guest success and fresh ConfigurationData/ConfigurationChange
records without restarting VMs. The handler remains auto-upgrade enabled.
See [Microsoft's supported CLI examples](https://learn.microsoft.com/azure/azure-change-tracking-inventory/change-tracking-inventory-support-matrix).

First inspect both extension surfaces and DCRAs read-only. Obtain scoped approval
before installation. Do not delete stuck Arc extensions, restart a VM or move
DCRAs incidentally. Provisioning success and data arrival are separate checks;
CT cycles/ingestion can lag substantially.

## Container App is healthy but readiness says pending

Healthy active revisions can report `RunningAtMaxScale` or `RunningAtMinScale`,
not only `Running`. The readiness check accepts these states. Compare a
timestamped app `runningStatus`, latest/latest-ready revision, active revision
`healthState`/`runningState` and `SIMULATE_CRASH` **without updating them**. A stale
snapshot or enum mismatch is not grounds to reset a workload fault.

## Preflight or redeployment now refuses a previously tolerated state

Preflight no longer registers providers or skips RBAC for a supplied principal.
Missing providers, insufficient effective permissions, malformed skins,
SKU restrictions and insufficient quota terminate with instructions.
Quota/listing checks are not capacity guarantees.
Routine redeployment does not reset SP credentials or generate a new password for
existing VMs. Old labs without the saved Key Vault secret need their **current**
password as `-AdminPassword` (SecureString); an existing SP needed for new
onboarding needs `-OnboardingSecret`. Obtain the current values from the operator;
do not rotate them as a shortcut. See [lifecycle semantics](lifecycle.md).

## Deploy fails immediately with `SkuNotAvailable`

**Symptom** — `Deploy-ArcDemo.ps1` fails at the VM creation phase with:
```
SkuNotAvailable: The requested VM size for resource 'Following SKUs have failed for Capacity Restrictions: Standard_B2as_v2' is currently not available in location 'australiaeast'.
```

**Cause** — Azure capacity restrictions on burstable B-series in AU regions, especially in MCAPS-style subscriptions.

**Fix** — Inspect restrictions and quota in the confirmed target:

```powershell
az vm list-skus --subscription <SUB> -l australiaeast --size Standard_B2as_v2 --all -o table
az vm list-usage --subscription <SUB> -l australiaeast -o table
```

Choose a permitted SKU/region and review the matching Bicep preview. Neither an
unrestricted SKU listing nor `--validate` guarantees physical allocation. Do not
create/delete arbitrary probe resource groups in an in-use lab.

## Clean deploy fails while creating DCRs with missing Log Analytics tables

**Symptom** — A first deployment into a clean subscription/prefix fails during
Data Collection Rule creation with a `BadRequest`, `table not found`, or stream
mapping error for `Perf`, `Event`, `Syslog`, `InsightsMetrics`, or
`ConfigurationData`.

**Cause** — A brand-new Log Analytics workspace and the VM Insights / Change
Tracking solutions can report `Succeeded` before their standard tables are
queryable by the DCR API.

**Fix** — Current `Deploy-ArcDemo.ps1` avoids the race by keeping DCRs out of
the initial Bicep deployment, waiting for the required tables, and then
upserting `dcr-arc-demo`, `dcr-vminsights`, and `dcr-changetracking` with
bounded retries. Re-run the deploy script; the DCR names and DCRA names are
deterministic, so reruns update existing resources instead of duplicating them.

## Arc machines show `Disconnected` shortly after deploy

**Symptom** — Arc Connected immediately after onboarding, then `Disconnected` after the first overnight auto-shutdown.

**Cause** — Earlier deployments relied on implicit default outbound rather than an explicit outbound path. Do not assume that path survives a deallocate/start cycle.

**Fix** — Fresh deployment now creates a **NAT Gateway** before compute/extension provisioning. Activation recreates it before starting parked VMs. For an older lab missing NAT, after approving activation, run:

```powershell
.\scripts\Activate-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath .\config\demo-skin.json
```

## No Heartbeat in Log Analytics for Linux hosts

**Symptom** — Windows hosts are beating; Linux hosts show 0 records in `Heartbeat`.

**Cause** — One of two:

1. The Linux Arc GC extension stack is broken on Ubuntu 22.04 with `MSFT_ARC_TEST=true`. The repo installs AMA via the Azure VM extension path on Linux, which sidesteps this. If you reverted that and installed via the Arc extension, you'll hit this.
2. The DCR association is on the **Azure VM** resource ID instead of the **Arc** resource ID. The Linux AMA detects Arc and pulls config from Arc IMDS, which only sees DCRA's attached to the Arc resource.

**Fix** — Inspect:

```powershell
# Should show AMA on the Azure VM ext list (Linux)
az vm extension list -g rg-arc-demo-infra --vm-name lnx-app-01

# Linux has core + CT DCRAs on the Arc resource; Linux VMI map is disabled.
az resource list -g rg-arc-demo --resource-type Microsoft.Insights/dataCollectionRuleAssociations
```

If a DCRA is wrongly attached to the backing Azure VM, obtain approval for the
exact association repair before changing/deleting anything. The intended Arc
association payload is:

```powershell
$sub = (az account show --query id -o tsv)
$arcId = "/subscriptions/$sub/resourceGroups/rg-arc-demo/providers/Microsoft.HybridCompute/machines/lnx-app-01"
$dcrId = "/subscriptions/$sub/resourceGroups/rg-arc-demo/providers/Microsoft.Insights/dataCollectionRules/dcr-arc-demo"
$body = @{ properties = @{ dataCollectionRuleId = $dcrId } } | ConvertTo-Json
$token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
Invoke-RestMethod -Method Put -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
  -Body $body `
  -Uri "https://management.azure.com$arcId/providers/Microsoft.Insights/dataCollectionRuleAssociations/dcra-core-lnx-app-01?api-version=2022-06-01"
```

Then restart AMA on the VM:
```powershell
az vm run-command invoke -g rg-arc-demo-infra -n lnx-app-01 --command-id RunShellScript `
  --scripts 'sudo systemctl restart azuremonitoragent'
```

Wait 5 min and re-check Heartbeat.

## Update Manager shows no update data after activation

**Symptom** - Azure Update Manager shows no update data, or Linux Arc machines
show `LinuxOsUpdateExtension` stuck in `Creating` or `Deleting`.

**Cause** - Periodic assessment only fetches data every 24 hours. The activation
script submits an on-demand assessment, but Update Manager creates temporary OS
update extensions and the portal data is asynchronous. In the current lab,
Windows assessment results complete reliably first; Linux extension provisioning
can lag.

**Fix** - First confirm the activation script submitted assessments:

```powershell
$start = (Get-Date).AddHours(-2).ToString('o')
az monitor activity-log list -g rg-arc-demo --start-time $start `
  --query "[?operationName.value=='Microsoft.HybridCompute/machines/assessPatches/action'].{time:eventTimestamp,status:status.value,resource:resourceId}" `
  -o table
```

Then inspect the update extension instance view:

```powershell
foreach ($name in az connectedmachine list -g rg-arc-demo --query "[].name" -o tsv) {
  $m = az connectedmachine show -g rg-arc-demo -n $name --expand instanceView -o json | ConvertFrom-Json
  $ext = @($m.resources | Where-Object { $_.name -in @('WindowsOsUpdateExtension','LinuxOsUpdateExtension') }) | Select-Object -First 1
  [pscustomobject]@{
    Name = $name
    Extension = $ext.name
    ProvisioningState = $ext.properties.provisioningState
    Message = $ext.properties.instanceView.status.message
  }
}
```

For the live demo, use the Windows assessment rows as the reliable proof point
and state that Linux assessment data is still processing if the Linux extension
has not reached `Succeeded`.

## `az` commands fail with `AuthorizationFailed` against the *wrong* subscription

**Symptom** — All your `az` commands suddenly start returning `AuthorizationFailed` against a sub ID you don't recognise.

**Cause** — When the CLI token expires and you're signed into multiple tenants, `az account show` silently falls back to a default subscription that *isn't* the demo target.

**Fix** — Always start a session with:

```powershell
az account set --subscription <YOUR_SUB>
az account show --query "{id:id,tenantId:tenantId,user:user.name}" -o table
```

The `Test-Prerequisites.ps1` script does this check for you.

## `az rest` 400/500s with weird URL parsing errors

**Symptom** — `az rest --url '...?api-version=...'` fails with errors like `?api-version was unexpected at this time` or `unrecognized arguments: ?api-version=...`.

**Cause** — On Windows, `az` shells through `cmd.exe`, which treats `?` as a wildcard and `()` as command grouping. URLs containing both — especially the OMS Solutions API (`solutions/VMInsights(law-name)?...`) — get mangled before reaching the API.

**Fix** — Use PowerShell's native `Invoke-RestMethod` with an `az`-issued bearer token instead. The `Invoke-AzRest` helper in `scripts/lib/Common.psm1` does this for you. Never use `az rest` for those URLs.

## `az policy assignment create` throws a Python traceback

**Symptom** — `az policy assignment create --policy-set-definition ...` returns an `AttributeError: 'NoneType' object has no attribute 'get'` or `'_data'`.

**Cause** — CLI 2.85 bug specifically with built-in policy *set* definitions on subscription scope.

**Fix** — Use `Invoke-RestMethod` PUT against the policyAssignments REST endpoint directly. The Bicep template in this repo handles this declaratively; if you're tweaking outside the template, the helper pattern is in `Deploy-ArcDemo.ps1`.

## SQL Best Practice Assessment hasn't run yet

This applies only to a **separate, supported SQL lab** using a real non-Azure SQL
Server host. The default Azure-only demo skips SQL Server, Arc SQL registration,
and BPA because SQL Server enabled by Azure Arc does not support SQL Server
running in Azure Virtual Machines as the validation target. See
[`sql-arc-spike.md`](sql-arc-spike.md).

**Symptom** — Arc SQL instance is registered, Defender shows protected, but the BPA tile in the Arc SQL portal blade is empty.

**Cause** — First BPA scan can take 30-60 min after the `WindowsAgent.SqlServer` extension reaches `Succeeded`.

**Fix** — Wait. To verify the extension is healthy:
```powershell
az connectedmachine extension show -g rg-arc-demo --machine-name win-sql-01 -n WindowsAgent.SqlServer --query "properties.provisioningState"
```

## Compliance scorecards (MCSB/NIST) are empty

**Symptom** — Policy assignments exist, but the **Regulatory compliance** page
in Defender for Cloud is blank.

**Cause** — First policy evaluation cycle takes ~12 hours after assignment.

**Fix** — Wait. To force evaluation:
```powershell
az policy state trigger-scan --resource-group rg-arc-demo
```
(Still takes 1-3 hours; "force" is relative.)

## Hibernate seems to skip the NAT GW delete

**Symptom** — Hibernate completes, but retained-service charges exceed an old estimate.

**Cause** — You may have other NAT GWs or public IPs in the same RG with different names that didn't get deleted.

**Fix** — Check:
```powershell
az network nat gateway list -g rg-arc-demo-infra -o table
az network public-ip list -g rg-arc-demo-infra -o table
```

The script only deletes `natgw-arc-demo` and `pip-natgw` (matching the default `-NamePrefix`). If you used `-NamePrefix foo`, the script uses `natgw-foo` and still `pip-natgw`. Adjust if needed.

## Cost is higher than expected

See [`cost.md`](cost.md) for the full breakdown by state. The most common surprises:

- **Defender for Servers Plan 2** uses published server/month pricing with applicable usage metering. Check the selected plan and actual billed coverage; VM deallocation is not a blanket promise of no Defender charges.
- **NAT Gateway/PIP** continue billing until removed. Successful hibernation verifies their absence.
- **Log Analytics** has ingestion and retention charges. Heavy debugging can increase ingestion; use current regional pricing and the workspace's actual usage, not an old hard-coded unit rate.

## "AGENTS.md says X, but the script does Y"

If you find a mismatch between [`AGENTS.md`](../AGENTS.md) and the actual scripts, **the scripts are the source of truth**. Please open an issue (or PR) so `AGENTS.md` can be brought back in line.
