# AI deploy handbook - Arc/Monitor spine

Use this when sharing the repo with another SE who wants an AI assistant to deploy
the standalone Arc + Azure Monitor demo.

## Give this prompt to the AI assistant

```text
You are deploying the reusable Azure Arc + Azure Monitor demo from
https://github.com/corey-skapin/arc-demo.

Read AGENTS.md, README.md, docs/runsheet.md, docs/troubleshooting.md, and
docs/sql-arc-spike.md before running commands.

Inputs:
- Subscription ID: <SUBSCRIPTION_ID>
- Tenant ID: <TENANT_ID>
- Notification email: <EMAIL>
- Customer skin file to use or create: config/demo-skin.json
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
3. Review config/demo-skin.json and update only customer-facing skin values.
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
```

## Required inputs

| Input | Notes |
|---|---|
| Subscription ID | Use a clean/new subscription where the operator has Owner. |
| Tenant ID | Must match the subscription tenant and later SRE Agent tenant. |
| Notification email | Used for budget and Action Group email receiver. |
| Region | Defaults to `australiaeast`; keep aligned with the SRE repo. |
| Name prefix | Defaults to `arc-demo`; keep short and lowercase for Azure names. |
| Workload flags | Keep the default Arc/Monitor spine on; add optional workloads only when needed. |

## Deployment order

```powershell
git clone https://github.com/corey-skapin/arc-demo C:\src\arc-demo
cd C:\src\arc-demo

az login --tenant <TENANT_ID>
az account set --subscription <SUBSCRIPTION_ID>

.\scripts\Test-Prerequisites.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID>

.\scripts\Deploy-ArcDemo.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json `
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
  -SkinPath .\config\demo-skin.json -DesiredState Ready -OutputFormat Json -TimeoutSeconds 600
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
| Monitor heartbeat | Log Analytics query: `Heartbeat \| where TimeGenerated > ago(30m)` |
| Workbook exists | Search **Workbooks** in the Azure portal and open `Arc Demo - Estate Overview` or the skin title. Fallback: resource group `rg-arc-demo` > Workbooks. |
| Action Group exists | `az monitor action-group show --subscription <SUB> -g rg-arc-demo -n ag-arc-demo` |
| Container App optional alert | `alert-arc-demo-containerapp-restarts` in `rg-arc-demo-infra` |
| SQL workload simulation optional | `docs/sql-workload-simulation.md` commands run against `win-sql-01` |

## Manual steps

None are expected for the Arc/Monitor spine after Azure sign-in and prerequisite
approval. Portal clicks are only for presenting the demo, not for deployment.

## SQL stance

Do not enable SQL by default. `docs/sql-arc-spike.md` documents the distinction:
SQL Server on an Azure VM is acceptable as a workload simulation, but SQL Server
enabled by Azure Arc should be validated on a real non-Azure SQL host and is not a
claim for this Azure-only lab.

## Hibernation

Hibernate only after the user explicitly approves parking this lab:

```powershell
.\scripts\Hibernate-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath .\config\demo-skin.json
```

Verify:

```powershell
.\scripts\Test-ArcDemoReadiness.ps1 -SubscriptionId <SUB> -TenantId <TENANT> `
  -SkinPath .\config\demo-skin.json -DesiredState Hibernated -OutputFormat Json
```

Expected hibernated state: all VMs deallocated, no NAT Gateway/Public IP, optional
Container App revisions inactive, optional AKS Stopped/Succeeded. Zero minimum
replicas alone is not a parked Container App; retained services/storage can bill.

## Hand off to SRE Agent

After this repo is deployed, use the companion repo:

```powershell
git clone https://github.com/corey-skapin/sre-agent-demo C:\src\sre-agent
```

Then follow `C:\src\sre-agent\docs\ai-deploy-handbook.md`.
