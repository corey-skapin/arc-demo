# AI deploy handbook - Arc/Monitor spine

Use this when sharing the repo with another SE who wants an AI assistant to deploy
the standalone Arc + Azure Monitor demo.
This is an **optional operator aid**, not another presentation guide.
[runbook.md](runbook.md) and [lifecycle.md](lifecycle.md) own operations;
[the docs index](README.md) routes first-time presenters to [runsheet.md](runsheet.md).

## Give this prompt to the AI assistant

```text
You are deploying the reusable Azure Arc + Azure Monitor demo from
<ARC_REPOSITORY_URL> supplied by the operator.

Read AGENTS.md, docs/README.md, docs/runbook.md, docs/lifecycle.md, docs/troubleshooting.md, and
docs/sql-arc-spike.md before running commands.

Inputs:
- Subscription ID: <SUBSCRIPTION_ID>
- Tenant ID: <TENANT_ID>
- Notification email: <EMAIL>
- Private runtime skin file: <PRIVATE_SKIN_PATH>, copied from a bundled synthetic example
- Desired workloads:
  - Arc/on-prem simulation: yes
  - Azure-native VM: <yes/no>
  - Container App fault alert: <yes/no>
  - AKS crash-loop: <yes/no>
  - SQL workload simulation: <yes/no, optional DBA signal after Arc deploy>
  - SQL Server enabled by Azure Arc: no for this Azure-only lab

Do:
1. Confirm Azure CLI is signed in to the specified tenant and subscription.
2. Run scripts/Test-Prerequisites.ps1.
3. Copy config/demo-skin.json outside git; put approved customer-facing/runtime values only in that private skin.
4. Deploy with scripts/Deploy-ArcDemo.ps1 using the skin and selected workload flags.
5. Run Test-ArcDemoReadiness.ps1 with the same explicit target/skin; preserve JSON evidence outside source. Verify guest/workload signals separately.
6. Record any manual follow-up clearly.
7. Hibernate only when the user explicitly approves parking the demo; pass the same subscription/tenant/skin.

Do not:
- Hard-code subscription, tenant, or private email values into source.
- Claim SQL Server enabled by Azure Arc in this Azure-only lab.
- Delete the lab unless asked to run scripts/Remove-ArcDemo.ps1.
- Change CLI default context, register providers, reset credentials/faults or alter shared Defender pricing incidentally.
- Run disruptive lifecycle smoke tests against an in-use lab.
- Treat a successful ARM submission, extension provisioning or patch submission as completed guest/telemetry validation.
- Treat Monitor readiness or healthy/licensed passive-mode Linux sensors as active-antivirus or full EDR proof.
- Park Arc before an attached SRE layer has completed its fault window and its own approved hibernation.
```

## Required inputs

| Input | Notes |
|---|---|
| Subscription ID | Use a demo subscription with effective Owner, or Contributor plus User Access Administrator. |
| Tenant ID | Must match the subscription tenant and later SRE Agent tenant. |
| Notification email | Used for budget and Action Group email receiver. |
| Region | Defaults to `australiaeast`; keep aligned with the SRE repo. |
| Name prefix | Defaults to `arc-demo`; keep short and lowercase for Azure names. |
| Workload flags | Keep the default Arc/Monitor spine on; add optional workloads only when needed. |

## Deployment order

```powershell
git clone <ARC_REPOSITORY_URL> C:\src\arc-demo
cd C:\src\arc-demo

az login --tenant <TENANT_ID>
az account set --subscription <SUBSCRIPTION_ID>

.\scripts\Test-Prerequisites.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID>

.\scripts\Deploy-ArcDemo.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_SKIN_PATH> `
  -AdminEmail <EMAIL> `
  -DeployAzureVMs $true `
  -DeployContainerApps $true
```

Add `-DeployAks $true` only when the SE wants the AKS beat and accepts the extra
time/cost. Keep `-InstallSql` off for this Azure-only lab.

## Validation checklist

First read [lifecycle.md](lifecycle.md). Use:

```powershell
.\scripts\Test-ArcDemoReadiness.ps1 -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_SKIN_PATH> -DesiredState Ready -OutputFormat Json -TimeoutSeconds 600
```

JSON v1 uses exact resource IDs and exit 0 pass, 1 fail/error, 2 pending.
Readiness never induces/resets faults. Missing skins/configs are errors. Preflight
is read-only and effective Owner or Contributor+UAA is mandatory; supplying a
principal ID does not skip RBAC. Preserve deployment history and existing VM/SP
credentials. Optional-only deployments can have empty fleets while older hosts
remain; never infer absence from the newest output alone.

| Check | Command or portal location |
|---|---|
| Correct subscription | `az account show --subscription <SUB> --query "{id:id,tenant:tenantId,user:user.name}" -o table` |
| Resource groups exist | `az group show --subscription <SUB> -n rg-arc-demo`; `az group show --subscription <SUB> -n rg-arc-demo-infra` |
| Arc machines connected | `az connectedmachine list --subscription <SUB> -g rg-arc-demo -o table` |
| Monitor heartbeat | Readiness requires Heartbeat within 10 minutes by every expected ARM `_ResourceId`, not just host names/counts. |
| Linux endpoint protection | Direct sensor health, mode and extension health are separate. Passive mode/RTP false is not active-antivirus proof; retain event-provider caveats. |
| Workbook exists | **Monitor** > **Workbooks** > saved **Workbooks** gallery; open `Arc Demo - Estate Overview` or the skin title, not a template. Use the operator's actual deployment workbook URL as an alternative, not an assumed resource-group Workbooks blade. |
| Action Group exists | `az monitor action-group show --subscription <SUB> -g rg-arc-demo -n ag-arc-demo` |
| Container App optional alert | `alert-arc-demo-containerapp-restarts` in `rg-arc-demo-infra` |
| SQL workload simulation optional | `docs/sql-workload-simulation.md` commands run against `win-sql-01` |

## Manual steps

No ad-hoc portal resource configuration is part of deployment. Sign-in,
prerequisites and any required recipient verification remain operator-owned.
An email receiver in the ARM model is not proof of verified delivery; current
[Action groups guidance](https://learn.microsoft.com/azure/azure-monitor/alerts/action-groups)
describes recipient-verification requirements. No test send, verification or
receiver change is authorized by this handbook or a readiness check.

## SQL stance

Do not enable SQL by default. `docs/sql-arc-spike.md` documents the distinction:
SQL Server on an Azure VM is acceptable as a workload simulation, but SQL Server
enabled by Azure Arc should be validated on a real non-Azure SQL host and is not a
claim for this Azure-only lab.

## Hibernation

Hibernate only after the user explicitly approves parking this lab:

```powershell
.\scripts\Hibernate-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath <PRIVATE_SKIN_PATH>
```

Verify:

```powershell
.\scripts\Test-ArcDemoReadiness.ps1 -SubscriptionId <SUB> -TenantId <TENANT> `
  -SkinPath <PRIVATE_SKIN_PATH> -DesiredState Hibernated -OutputFormat Json
```

Expected hibernated state: all VMs deallocated, no NAT Gateway/Public IP, optional
Container App revisions inactive, optional AKS Stopped/Succeeded. Zero minimum
replicas alone is not a parked Container App; retained services/storage can bill.
Keep the runtime target, skin/fleet inputs, revision/fault state and deployment
history outside git. An attached SRE layer must be parked first through its own
procedure. Activation can restart guest agents and submit asynchronous patch
assessments; targeted VM-start/readiness evidence does not validate that whole path.
Use normal lifecycle context/inventory/network preview, not the deployment
Graph/Owner/capacity preflight as a parking gate. Hibernate parks all compute in
the explicit infra group despite manifest/OS/skin drift. Unsafe network cleanup
warns and skips only NAT/PIP; inspect non-required network cost rows before
claiming cleanup. Retained monitoring is not a parking gate. Unknown/denied
power inspection is an error, not verified stopped compute. Already-active activation
retries verify guests without resubmitting assessments; `-AssessPatches` is the
explicit all-host assessment request. User-facing states are Active, Hibernated
and Removed, with Ready retained as the compatibility alias for Active.
Concurrent guest checks allow ten minutes for AMA startup. Telemetry-only lag
records pending without failing activation; poll readiness to pass before the
presentation, dependent SRE layer or incident offer. Unhealthy services still fail.

## Hand off to SRE Agent

For an explicitly requested **combined Arc + SRE activation**, the AI completes
Arc activation and verifies `Ready`, then continues in the configured companion
checkout using its canonical
[post-activation incident offer](https://github.com/corey-skapin/sre-agent-demo/blob/main/docs/ai-deploy-handbook.md#post-activation-incident-offer).
After SRE activation/config/application readiness succeeds, that flow asks once
whether the user wants the existing incident. If declined, leave the demo ready.
If agreed, the AI runs the established T09 scenario and manages observation and
recovery while preserving the human's actual Review approval. The user need not
know script names or execute a runbook. Do not add a script/orchestrator prompt
or duplicate the companion's offer. **Arc-only activation has no incident offer or fault.**
