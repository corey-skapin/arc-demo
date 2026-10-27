# Azure Arc demo build and operations runbook

**Operator procedure, not the presentation script.** Presenters start at
[the docs index](README.md), then their generated `.local/presenter-runsheet.md`.
The maintained deployment path is `scripts\Deploy-ArcDemo.ps1` plus Bicep. Do not
replay old ad-hoc portal/CLI builds against a running demo. Start with
[AGENTS.md](../AGENTS.md), [lifecycle safety/contract](lifecycle.md), and the
[presenter template](runsheet.md) only when preparing the local guide.

## Prepare the local presenter guide

Do this after successful approved deployment/activation and independent Active
readiness. The presenter receives `.local/presenter-runsheet.md` and follows it
top to bottom; no input card, customer customization or ID lookup is required.
Deployment/lifecycle behavior is unchanged.

Plain Markdown cannot interpolate an external JSON file. The offline
`scripts\New-PresenterRunsheet.ps1` fills the single tracked `docs\runsheet.md`
template from `.local\demo-context.json`. The entire `.local/` folder is ignored.
Capture the following **nonsecret** fields from the explicit setup inputs and
actual deployment outputs/saved evidence, never CLI defaults or guessed IDs:

| Field | Source |
|---|---|
| `schemaVersion` | Numeric `1` |
| `subscriptionId`, `tenantId` | The operator-confirmed runtime target |
| `recordedAtUtc` | UTC timestamp of the context/evidence being saved, not the generation time |
| `resourceGroups` | Object with actual `arc` and `infra` group names |
| `workspaceResourceId`, `workbookResourceId` | Exact workspace and saved Estate Overview workbook IDs |
| `windowsMachineResourceId`, `linuxMachineResourceId` | Exact monitored Arc machine IDs selected for the tour, not backing VM IDs |
| `heartbeatAlertResourceId`, `actionGroupResourceId` | Exact heartbeat rule and action group IDs |
| `lobMachineName` (optional) | The separately prepared LOB host; omit if not part of this demo |
| `companionSreRunsheetPath` (optional) | Absolute path to the companion's actual generated guide; linked only if it exists |

The assistant/operator writes the approved values once, then runs:

```powershell
# $context contains only the fields above, from approved inputs and saved outputs.
New-Item -ItemType Directory -Path .\.local -Force | Out-Null
$context | ConvertTo-Json -Depth 4 | Set-Content .\.local\demo-context.json
.\scripts\New-PresenterRunsheet.ps1
```

No sign-in, Azure read/write, guest command or health check occurs in generation.
Missing/foreign/malformed IDs fail explicitly before replacing the output.
The context timestamp is printed prominently: old evidence is not current health.
The generator does not read a credential store, copy a whole deployment manifest
or retain passwords, recipient emails, tokens or private configuration files.

Refresh the context and regenerate after successful preparation changes the
resources or selected hosts. An activation that leaves telemetry pending is not
a successful presenter handoff; poll readiness under the normal contract first.
The operator owns that check, not the presenter. Use the same convention in the
companion repo; a missing companion guide produces a plain handoff note, not a
broken or guessed relative path.

## 1. Choose the target and skin

Use a demo subscription where the operator has effective subscription Owner or
Contributor plus User Access Administrator, and permission to create an Arc
onboarding identity if needed. PowerShell 7.4+, Azure CLI 2.60+ and Bicep are
required. No Az PowerShell module, production framework or SRE Agent is required.

```powershell
az login --tenant <TENANT>
az account show --subscription <SUB> --query "{id:id,tenantId:tenantId,user:user.name}" -o table
$target = @{ SubscriptionId = '<SUB>'; TenantId = '<TENANT>'; SkinPath = '<PRIVATE_SKIN_PATH>' }
```

Confirm those values; do not rely on default CLI context. Copy a bundled skin
outside git for a new lab; edit that private copy's email, labels, prefix and
workload toggles. Preserve an existing lab's retained inputs instead.
IDs and secrets stay out of source.
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

Match the effective disk tier too: fresh deployments default to SSD, but an
existing HDD lab requires `-OsDiskStorageAccountType Standard_LRS` or that value
in its private skin. The wrapper refuses mismatches even during preview; it
does not convert disks. Preserve the operator-chosen HDD tier and plan any
migration separately before HDD OS support retirement. See [cost.md](cost.md).

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

Hibernation parks all VM/AKS/Container App compute in the explicitly targeted demo
infra group, even if deployment manifests, OS metadata or skin drift; drift warns.
It verifies deallocation/AKS stop/inactive revisions before safe NAT/PIP removal.
Foreign/shared bindings skip only networking with a loud residual-cost warning.
Data, identities and fault flags remain. Failed compute attempts do not block
attempts on other hosts/workloads; unknown/denied final power is not success.
Activation restores outbound NAT first, starts retained workloads and reconnects
agents where needed. Every run verifies guests, including already-connected hosts,
without unnecessary restarts; Windows Arc AMA uses a `MonAgentCore` process check.
Host checks run concurrently with a ten-minute AMA budget and per-host evidence.
An AMA timeout records pending; required service failures still fail.
Telemetry-only pending does not fail activation, but must be rechecked through
readiness before the presentation or dependent SRE/incident-offer flow continues.
Default assessment submissions cover newly started/waking Arc hosts only;
already-active retries do not resubmit. `-AssessPatches` explicitly requests
all-host assessments (including assessment-phase retries). Use optional `-ResultPath`
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
Its required acceptance covers parked compute/app state; NAT/PIP absence is a
non-required cost diagnostic. Exit 0 can therefore coexist with incomplete
network cleanup. Retained monitoring is not queried as a parking gate; actual
inspection/auth errors still fail rather than being misreported as absence.
Use normal lifecycle `-WhatIf`, not deployment Graph/Owner/quota preflight or
historical whole-group index comparisons. Exact network sharing is checked
before network writes. On partial failure, retry without redeploying or waking compute.
Enabled alerts can still evaluate/notify and incur charges; there is no automatic
pause/restore of their previous enabled state.

## 6. Remove permanently (separate destructive approval)

```powershell
.\scripts\Remove-ArcDemo.ps1 @target -WhatIf
.\scripts\Remove-ArcDemo.ps1 @target
.\scripts\Test-ArcDemoReadiness.ps1 @target -DesiredState Removed -OutputFormat Json
```

This deletes both demo groups and named policies/budget and verifies all their
absence. Defender pricing is preserved unless `-DisableDefender` is explicitly
requested. `-RemoveOnboardingIdentity` is separately opt-in and rejects shared or
ambiguous identities. Inspect remaining subscription/tenant resources and delayed
billing; do not promise zero charges just because group deletion completed.
Default Removed verification needs no deployment history or Graph lookup;
tenant identities/applications, shared services and soft-deleted vaults are
explicit exclusions. Active readiness also accepts the legacy `Ready` name.

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
