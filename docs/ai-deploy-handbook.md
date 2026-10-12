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
  - SQL/Arc SQL: no for this Azure-only lab

Do:
1. Confirm Azure CLI is signed in to the specified tenant and subscription.
2. Run scripts/Test-Prerequisites.ps1.
3. Review config/demo-skin.json and update only customer-facing skin values.
4. Deploy with scripts/Deploy-ArcDemo.ps1 using the skin and selected workload flags.
5. Validate Arc machines, workbook, Log Analytics Heartbeat, alert rules, and optional workload resources.
6. Record any manual follow-up clearly.
7. Hibernate with scripts/Hibernate-ArcDemo.ps1 when finished.

Do not:
- Hard-code subscription, tenant, or private email values into source.
- Enable SQL/Arc SQL in this Azure-only lab unless explicitly asked after reading docs/sql-arc-spike.md.
- Delete the lab unless asked to run scripts/Remove-ArcDemo.ps1.
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

| Check | Command or portal location |
|---|---|
| Correct subscription | `az account show --query "{id:id,tenant:tenantId,user:user.name}" -o table` |
| Resource groups exist | `az group show -n rg-arc-demo`; `az group show -n rg-arc-demo-infra` |
| Arc machines connected | `az connectedmachine list -g rg-arc-demo -o table` |
| Monitor heartbeat | Log Analytics query: `Heartbeat | where TimeGenerated > ago(30m)` |
| Workbook exists | Azure Arc > Workbooks > `Arc Demo - Estate Overview` or skin title |
| Action Group exists | `az monitor action-group show -g rg-arc-demo -n ag-arc-demo` |
| Container App optional alert | `alert-arc-demo-containerapp-restarts` in `rg-arc-demo-infra` |

## Manual steps

None are expected for the Arc/Monitor spine after Azure sign-in and prerequisite
approval. Portal clicks are only for presenting the demo, not for deployment.

## SQL stance

Do not enable SQL by default. `docs/sql-arc-spike.md` documents the support
boundary: Arc-enabled SQL Server is a strong follow-on for real non-Azure SQL
hosts, but this Azure-VM-backed simulation is not the supported validation target.

## Hibernation

Always hibernate when the live rehearsal is finished:

```powershell
.\scripts\Hibernate-ArcDemo.ps1 -SkinPath .\config\demo-skin.json
```

Verify:

```powershell
az vm list -g rg-arc-demo-infra -d --query "[].{name:name,power:powerState}" -o table
az resource list -g rg-arc-demo-infra --resource-type Microsoft.Network/natGateways -o table
az resource list -g rg-arc-demo-infra --resource-type Microsoft.Network/publicIPAddresses -o table
az containerapp list -g rg-arc-demo-infra --query "[].{name:name,min:properties.template.scale.minReplicas}" -o table
```

Expected hibernated state: all VMs deallocated, no NAT Gateway/Public IP, optional
Container App min replicas `0`.

## Hand off to SRE Agent

After this repo is deployed, use the companion repo:

```powershell
git clone https://github.com/corey-skapin/sre-agent-demo C:\src\sre-agent
```

Then follow `C:\src\sre-agent\docs\ai-deploy-handbook.md`.
