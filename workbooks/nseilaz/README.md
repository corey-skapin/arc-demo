# Azure Arc workbooks — by Nic Seilaz

These workbook templates come from **[github.com/nseilaz/AzureArc_Workbooks](https://github.com/nseilaz/AzureArc_Workbooks)** and are vendored here (not git-submoduled) so the demo deploys are reproducible against a known-good snapshot.

**License:** MIT — see [`LICENSE.upstream`](LICENSE.upstream).
**Credit:** All workbook content authored by [Nic Seilaz](https://github.com/nseilaz).

## What's in here

| File | Workbook | What it shows |
|---|---|---|
| `Arc_Compliance_Security_Governance_example.json` | Compliance, Security & Governance | Estate inventory, NIST CSF v2 compliance, patch posture, privileged activity, TLS hardening, Defender alerts, configuration drift. |
| `ArcMachineIntelligenceCenter.json` | Arc Machine Intelligence Center | 360° view of one Arc machine: live perf, security health, CVSS vulns, software history, SQL (if applicable), Arc mgmt, ops timeline. |
| `Asset_Inventory_Workbook_Example.json` | Asset Inventory | Estate-wide hardware/software inventory roll-up. |
| `GovernanceComplianceWorkbook_Experiment.json` | Governance & Compliance (experimental) | Larger compliance workbook with deeper drill-downs. |
| `SQL_Estate_Dashboard.json` | SQL Estate Dashboard | Arc-enabled SQL inventory + Best Practice Assessment results. |

## How they get into your workspace

`scripts/Deploy-ArcDemo.ps1` reads each file, sets `sourceId` to your demo workspace, and PUTs them as shared workbooks in the Arc resource group. They appear under **Azure Arc → Workbooks**.

## Updating the snapshot

To pull the latest from upstream:

```powershell
$dest = "C:\src\arc-demo\workbooks\nseilaz"
$files = @(
  'ArcMachineIntelligenceCenter.json',
  'Arc_Compliance_Security_Governance_example.json',
  'Asset_Inventory_Workbook_Example.json',
  'GovernanceComplianceWorkbook_Experiment.json',
  'SQL_Estate_Dashboard.json'
)
foreach ($f in $files) {
  Invoke-WebRequest -UseBasicParsing `
    -Uri "https://raw.githubusercontent.com/nseilaz/AzureArc_Workbooks/main/workbooks/$f" `
    -OutFile (Join-Path $dest $f)
}
```
Then re-run `Deploy-ArcDemo.ps1` — workbook PUTs are idempotent (matched on a `workbookTag` tag derived from the display name; re-runs of the same display name are no-ops).
