# Troubleshooting

> Every failure mode I've personally hit during build or operation, with a verified fix.
> If you hit something not listed here, please open an issue (or PR a fix in this file).

## Deploy fails immediately with `SkuNotAvailable`

**Symptom** — `Deploy-ArcDemo.ps1` fails at the VM creation phase with:
```
SkuNotAvailable: The requested VM size for resource 'Following SKUs have failed for Capacity Restrictions: Standard_B2as_v2' is currently not available in location 'australiaeast'.
```

**Cause** — Azure capacity restrictions on burstable B-series in AU regions, especially in MCAPS-style subscriptions.

**Fix** — Probe other SKUs in the region:

```powershell
foreach ($s in 'Standard_B2as_v2','Standard_D2as_v5','Standard_D2s_v5','Standard_E2as_v5') {
  az group create -n rg-skutest -l australiaeast --only-show-errors | Out-Null
  $err = az vm create -g rg-skutest -n probe -l australiaeast `
    --image MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest `
    --size $s --admin-username azureuser --admin-password 'P@ssw0rd-Probe-123!' `
    --authentication-type password --public-ip-address '""' --nsg '""' `
    --validate --only-show-errors 2>&1 | Out-String
  if ($err -match "SkuNotAvailable") { "❌ $s" } else { "✅ $s" }
}
az group delete -n rg-skutest --yes --no-wait
```

Then re-deploy with `-VmSize <working-sku>`.

## Arc machines show `Disconnected` shortly after deploy

**Symptom** — Arc Connected immediately after onboarding, then `Disconnected` after the first overnight auto-shutdown.

**Cause** — Azure **default outbound is being deprecated**. New VMs use it on first boot but lose it after deallocate/start.

**Fix** — The `Activate-ArcDemo.ps1` script creates a **NAT Gateway** before starting VMs. If you deployed before the NAT GW existed, run:

```powershell
.\scripts\Activate-ArcDemo.ps1 -SkipValidate
# Then restart Arc agent on each VM
foreach ($v in (az vm list -g rg-arc-demo-infra --query "[].name" -o tsv)) {
  $cmd = if ($v -like 'win-*') { 'RunPowerShellScript' } else { 'RunShellScript' }
  $script = if ($v -like 'win-*') { 'Restart-Service himds -Force' } else { 'sudo systemctl restart himdsd' }
  az vm run-command invoke -g rg-arc-demo-infra -n $v --command-id $cmd --scripts $script
}
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

# Should show 3 DCRAs (core, VMI, CT) attached to the ARC resource
az resource list -g rg-arc-demo --resource-type Microsoft.Insights/dataCollectionRuleAssociations
```

If DCRA is on Azure VM, delete it and create against Arc:

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

**Symptom** — Arc SQL instance is registered, Defender shows protected, but the BPA tile in the Arc SQL portal blade is empty.

**Cause** — First BPA scan can take 30-60 min after the `WindowsAgent.SqlServer` extension reaches `Succeeded`.

**Fix** — Wait. To verify the extension is healthy:
```powershell
az connectedmachine extension show -g rg-arc-demo --machine-name win-sql-01 -n WindowsAgent.SqlServer --query "properties.provisioningState"
```

## Compliance scorecards (MCSB/NIST) are empty

**Symptom** — Policy assignments exist, but Defender for Cloud → Regulatory compliance is blank.

**Cause** — First policy evaluation cycle takes ~12 hours after assignment.

**Fix** — Wait. To force evaluation:
```powershell
az policy state trigger-scan --resource-group rg-arc-demo
```
(Still takes 1-3 hours; "force" is relative.)

## Hibernate seems to skip the NAT GW delete

**Symptom** — Hibernate completes, but next month's cost is still ~AUD 90, not AUD 35.

**Cause** — You may have other NAT GWs or public IPs in the same RG with different names that didn't get deleted.

**Fix** — Check:
```powershell
az network nat gateway list -g rg-arc-demo-infra -o table
az network public-ip list -g rg-arc-demo-infra -o table
```

The script only deletes `natgw-arc-demo` and `pip-natgw` (matching the default `-NamePrefix`). If you used `-NamePrefix foo`, the script uses `natgw-foo` and still `pip-natgw`. Adjust if needed.

## Cost is higher than expected

See [`cost.md`](cost.md) for the full breakdown by state. The most common surprises:

- **Defender for Servers Plan 2** is billed *per server-hour*. If you forgot to enable auto-shutdown, expect ~AUD 180/mo for 8 servers running 24/7.
- **NAT Gateway** is ~AUD 55/mo on its own. Hibernate deletes it.
- **Log Analytics ingestion** is ~AUD 0.30 per GB-day above the free tier. Heavy debugging (e.g. turning on every event log) can spike this.

## "AGENTS.md says X, but the script does Y"

If you find a mismatch between [`AGENTS.md`](../AGENTS.md) and the actual scripts, **the scripts are the source of truth**. Please open an issue (or PR) so `AGENTS.md` can be brought back in line.
