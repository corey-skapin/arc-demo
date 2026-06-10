# Arc Demo — Live Run-Sheet

> Story-first walkthrough, modelled on Nic Seilaz's flow from the 13 May 2026 runthrough.
> Total time at a relaxed pace: **15–25 min**. Strip ruthlessly to fit shorter slots.

## Before the meeting (T-30 min)

1. Confirm VMs are running:
   ```powershell
   az account set --subscription 6ff7d039-8bfd-4cdb-8d74-f7a9f1eb9ff5
   $rg = "rg-arc-demo-infra"
   $stopped = az vm list -g $rg --show-details --query "[?powerState!='VM running'].name" -o tsv
   foreach ($v in $stopped) { az vm start -g $rg -n $v --no-wait }
   ```
2. Restart Arc agent on each VM if any show `Disconnected` in the portal (only needed if outbound was interrupted):
   ```powershell
   $vms = @('win-app-01','win-app-02','win-app-03','win-sql-01','win-sql-02')
   foreach ($v in $vms) {
     az vm run-command invoke -g $rg -n $v --command-id RunPowerShellScript --scripts "Restart-Service himds,AzureMonitorAgent -Force"
   }
   ```
3. Open these tabs in advance (always-on background while you talk):
   - **Workbook**: Azure Arc → Servers → Workbooks → "Arc Demo — Estate Overview" (rg-arc-demo)
   - **Defender for Cloud → Regulatory compliance** (subscription scope)
   - **Defender for Cloud → Recommendations** (subscription scope)
   - **Azure Arc → Servers → Inventory** (built-in workbook)
   - **Azure Arc → SQL Server instances**
   - **rg-arc-demo → Logs (Log Analytics)** with a saved KQL query window open

---

## The flow

### 1. Frame — "Why are we here?"  (~1 min)
- *"Customer has 235 Windows servers and 74 SQL instances on VMware. They're paying for Defender for Servers on EA. Their main question is: 'why bother with Arc?'"*
- Set the rule: **don't open the Arc blade first**. Lead with insights and let the customer ask "wait, how do we get this?"

### 2. Estate connectivity workbook  (~2 min) — *exec lens*
- Open **Arc — Compliance, Security & Governance** (from Nic's library) for the heavyweight scorecard view, or **Arc Demo — Estate Overview** (our custom one-pager) for a quick at-a-glance.
- Walk through tiles top-to-bottom:
  - "8 hosts beating, mix of Windows/Linux"
  - "Tagging hygiene — half my fleet is missing ownership tags. *In your environment, that's hundreds of unattributed servers.*"
  - "Top 25 applications across the estate — *this is the start of an app-rationalisation conversation*."
- Key line: **"This is what a head of platform wants to see Monday morning. Not blades, not agents, not policies."**

### 3. Regulatory compliance  (~3 min) — *security lens*
- Switch to **Defender for Cloud → Regulatory compliance**.
- Show MCSB scorecard + NIST 800-53 Rev 5 (we assigned both).
- Highlight a failed control, drill into the affected resource (one of our Arc machines).
- *"This is the same surface for on-prem Windows, on-prem Linux, AWS EC2, GCP Compute — Arc unifies all of them under one compliance posture."*

### 4. Vulnerability management  (~3 min) — *security lens*
- **Defender for Cloud → Recommendations** filtered to "Machines should have vulnerability findings resolved".
- Open one machine → MDVM panel → show a CVE with CVSS.
- Tie it back: *"This data comes from Defender for Endpoint, which Defender Plan 2 auto-deployed to every Arc machine — no SCCM, no SCOM, no third-party agent we had to wedge in."*

### 5. Inventory & change tracking  (~3 min) — *ops lens*
- Open **Arc — Asset Inventory** (Nic's library) for software-across-the-estate, then KQL `ConfigurationChange | where TimeGenerated > ago(7d) | summarize Changes=count() by Computer, ConfigChangeType`.
- *"Software-installed, service-changed, file-changed, registry-changed — all event-driven, like cloud. Customers replacing SCOM love this."*

### 6. SQL on Arc  (~3 min) — *DBA lens*
- Open **Arc — SQL Estate Dashboard** (from Nic's library) for the cross-estate view, then **Azure Arc → SQL Server instances → win-sql-01** for the drill-down.
- Show **Best practice assessment** results (will be populated after the first run).
- *"BPA needs Software Assurance — most enterprise customers already have it. They get this for free."*
- Mention migration assistant + automated backup as the follow-on conversation.

### 7. Performance deep-dive  (~2 min) — *ops lens*
- Open **Arc — Machine Intelligence Center** (Nic's library) and select the worst-performing host → live CPU/memory/disk/network + change events + CVSS vulns all on one page.
- *"This is the conversation that saves customers from upgrading to a bigger SQL Standard core licence when their actual peak is 35%."*

### 8. Alerts & ITSM story  (~2 min)
- **rg-arc-demo → Alerts** → show `alert-host-missing-heartbeat`.
- Show the **Action Group** → call out the **note in the runbook**: *"In a real customer environment we'd add a second action on this Action Group — a webhook to ServiceNow/PagerDuty/anything HTTP. Single switch on the CLI."*
- Optional live demo: `az vm deallocate -g rg-arc-demo-infra -n win-app-01` → wait, email arrives.

### 9. Now the Arc blade  (~2 min)
- Only NOW open **Azure Arc → Servers**.
- Show extension allow/block list, RBAC, audit trail.
- Key line: *"The machine owner stays in control. Central platform can't push arbitrary code without an approval path."*

### 10. Wrap  (~1 min)
- Reset the question: *"You came in asking why Arc. The answer is: because everything we just looked at applies equally to your VMware estate without lifting and shifting it."*

---

## Useful one-liners for live demos

```powershell
# Force an alert to fire (deallocate one host, wait 15 min, email arrives)
az vm deallocate -g rg-arc-demo-infra -n win-app-01

# Restart it after the demo
az vm start -g rg-arc-demo-infra -n win-app-01

# Show a fresh change event in the dashboard
az vm run-command invoke -g rg-arc-demo-infra -n win-app-02 `
  --command-id RunPowerShellScript `
  --scripts "Install-WindowsFeature -Name Telnet-Client"
```

## After the meeting

- Auto-shutdown takes care of itself at 19:00 ACDT.
- If you started VMs outside the schedule, deallocate them when done:
  ```powershell
  foreach ($v in (az vm list -g rg-arc-demo-infra --query "[].name" -o tsv)) {
    az vm deallocate -g rg-arc-demo-infra -n $v --no-wait
  }
  ```

## Operating cost notes

- ~AUD 210/mo steady-state with 19:00 ACDT auto-shutdown (Defender Plan 2 prorates because deallocated VMs aren't billed).
- Budget alert fires at 50/80/100% actual + 100% forecast → email to `coreyskapin@microsoft.com`.
- Biggest line items: Defender for Servers Plan 2 (~AUD 80), VM compute (~AUD 90).
