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

`scripts/Deploy-ArcDemo.ps1` reads each file, sets `sourceId` to your demo workspace, and PUTs them as shared workbooks in the Arc resource group. Search **Workbooks** and choose the demo group/workspace; the Arc portal navigation can vary.

A vendored workbook is a presentation template, not proof its data sources are
populated. In particular, keep SQL Estate/BPA out of the default Azure-only lab's
validated story; see [SQL stance](../../docs/sql-arc-spike.md).

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

The deploy wrapper upserts matching `workbookTag` identities derived from display
names and updates their content; a repeated display name is not a promise of
zero writes. A full deployment also reconciles infrastructure, not just workbooks.
Preview/review its scope and obtain approval before rerunning it against a lab.
