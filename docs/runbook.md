# Azure Arc demo build and operations runbook

The maintained deployment path is `scripts\Deploy-ArcDemo.ps1` plus Bicep. Do not
replay old ad-hoc portal/CLI builds against a running demo. Start with
[AGENTS.md](../AGENTS.md), [lifecycle safety/contract](lifecycle.md), and the
[presenter runsheet](runsheet.md).

## 1. Choose the target and skin

Use a demo subscription where the operator has effective subscription Owner or
Contributor plus User Access Administrator, and permission to create an Arc
onboarding identity if needed. PowerShell 7.4+, Azure CLI 2.60+ and Bicep are
required. No Az PowerShell module, production framework or SRE Agent is required.

```powershell
az login --tenant <TENANT>
az account show --subscription <SUB> --query "{id:id,tenantId:tenantId,user:user.name}" -o table
$target = @{ SubscriptionId = '<SUB>'; TenantId = '<TENANT>'; SkinPath = '.\config\demo-skin.json' }
```

Confirm those values; do not rely on default CLI context. Edit the skin's email,
labels, prefix and workload toggles. IDs and secrets stay out of source.
`config\dummy-customer.demo-skin.json` illustrates portability. An explicit missing
skin, malformed boolean, invalid prefix or fleet is an error, never a fallback.
Relative fleet paths resolve against the repo root.

## 2. Read-only preflight and preview

```powershell
.\scripts\Test-Prerequisites.ps1 -SubscriptionId <SUB> -TenantId <TENANT>
.\scripts\Deploy-ArcDemo.ps1 @target -AdminEmail <EMAIL> -WhatIf
```

Preflight does not register providers or change context. Resolve any missing
provider with separate operator authorization, using the exact providers reported
by deployment preflight for the selected workloads. Supplying
`-DeployerPrincipalId <OBJECT_ID>` bypasses only Graph user discovery, not RBAC.
SKU restriction and regional/family vCPU quota checks do not guarantee capacity.
Review [cost assumptions](cost.md) before agreeing to a budget.

## 3. Deploy (approved creation/reconciliation)

```powershell
.\scripts\Deploy-ArcDemo.ps1 @target -AdminEmail <EMAIL>
```

Default: 5 Windows Server hosts across 2016/2019/2022 and 3 Ubuntu 22.04 hosts,
Arc-enabled with `MSFT_ARC_TEST=true` for this demo-only simulation. SQL-capable
hosts do not imply SQL Server is installed. Optional flags are independent:
`-DeployAzureVMs $true`, `-DeployContainerApps $true`, `-DeployAks $true`.
For custom tiers, use `-OnPremFleetPath <fleet.json>`; see
[legacy fleet support](legacy-os-fleet.md). Represented legacy hosts are not
reported as deployed.

Bicep provisions static resources in `rg-<prefix>` (Arc/Monitor) and
`rg-<prefix>-infra` (backing/optional compute). The wrapper handles DCR table
readiness/retries, NAT, Arc onboarding, supported extensions/DCRAs and workbooks.
Linux AMA and CT use VM extensions but Arc DCRAs. Windows VM Insights map is
supported by the lab; Linux map remains disabled. Runtime errors stop deployment
rather than printing a false success.

### Existing estates and partial failures

Do not deploy over an in-use estate just to test a code change. First collect
read-only readiness and propose the exact required reconciliation.
Preserve subscription deployment history: it is the lifecycle manifest.
Incremental optional-only deployments do not delete earlier Arc hosts.

VM credentials are not regenerated on a routine redeploy. Reuse the existing
Key Vault secret; old labs without it must supply their **current**
`-AdminPassword` as a SecureString. New Arc onboarding with an existing SP
requires its existing `-OnboardingSecret`; no routine SP credential reset.
Resolve missing credentials with the operator, never silently rotate them.

## 4. Validate, then rehearse

```powershell
.\scripts\Test-ArcDemoReadiness.ps1 @target -DesiredState Ready -OutputFormat Json -TimeoutSeconds 600
$LASTEXITCODE
```

Exit 0 means required infrastructure/monitor checks pass, 1 is fail/error, 2 is
still pending. Save the timestamped JSON outside source. Check policy, Defender,
Update Manager assessment completion, CT inventory and optional workload behavior
in their own surfaces; a provisioned extension is not proof of telemetry or
completed assessment. Policy scores and CT cycles may take substantially longer
than infrastructure provisioning.

For Linux, inspect direct sensor health separately from MDE extension state.
The approved diagnostics found healthy/licensed sensors in passive mode with
real-time protection disabled, and retained an extension/direct-health
event-provider discrepancy. A Monitor pass is not active AV or full EDR proof.

Rehearse the [20-30 minute Arc/Monitor story](runsheet.md). The optional companion
SRE repo consumes these existing alerts; it does not replace the standalone Arc
operations plane. Reset/induce faults only as separately authorized scenario
actions. Do not claim Arc SQL validation; see [SQL stance](sql-arc-spike.md).

## 5. Park and wake (separate disruptive approval)

```powershell
.\scripts\Hibernate-ArcDemo.ps1 @target -WhatIf
.\scripts\Hibernate-ArcDemo.ps1 @target
.\scripts\Test-ArcDemoReadiness.ps1 @target -DesiredState Hibernated
.\scripts\Activate-ArcDemo.ps1 @target -WhatIf
.\scripts\Activate-ArcDemo.ps1 @target
```

Hibernation verifies exact VM deallocation, stops optional AKS, deactivates
Container App revisions, then removes NAT/PIP. Data and fault flags remain.
Activation restores outbound NAT first, starts retained workloads and reconnects
agents where needed. Every run verifies guests, including already-connected hosts,
without unnecessary restarts; Windows Arc AMA uses a `MonAgentCore` process check.
Default assessment submissions also run on retries. Use optional `-ResultPath`
in an existing private directory to preserve per-host outcomes, and distinguish
script completion from Monitor Ready and asynchronous assessment completion.
It does not reset faults. Optional AKS can take longer and
requires a 15-30 minute stop/start separation; capacity is not guaranteed.
Nightly VM auto-shutdown is not whole-lab hibernation.

Retain runtime target/skin/fleet inputs and deployment history outside git.
If SRE is attached, park that dependent layer first through its own maintained
procedure; on wake, restore Arc/Monitor and verify Ready before SRE resumes.
Hibernation is not cleanup: it does not delete groups, disks, Arc identities,
Key Vault secrets, onboarding credentials, DCRs or the workspace.

## 6. Remove permanently (separate destructive approval)

```powershell
.\scripts\Remove-ArcDemo.ps1 @target -WhatIf
.\scripts\Remove-ArcDemo.ps1 @target
```

This deletes both demo groups and named policies/budget and waits for group
absence. Defender pricing is preserved unless `-DisableDefender` is explicitly
requested. `-RemoveOnboardingIdentity` is separately opt-in and rejects shared or
ambiguous identities. Inspect remaining subscription/tenant resources and delayed
billing; do not promise zero charges just because group deletion completed.

## 7. Local development validation

```powershell
Invoke-ScriptAnalyzer -Path .\scripts -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path .\tests -CI
az bicep build --file .\bicep\main.bicep --stdout > $null
```

Pester is development-only, installed in CI; it is not a deployment dependency.
Fresh deploy, double deploy, park/wake and teardown/recreate remain separate
live smoke tests needing a disposable lab and explicit approval. See
[troubleshooting](troubleshooting.md) for known failure modes.
The approved eight-host active/readiness proof is not evidence that these
separate deployment or lifecycle cycles have been exercised.
