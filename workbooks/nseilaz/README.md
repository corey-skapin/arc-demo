# Azure Arc workbooks — by Nic Seilaz

These workbook templates come from **[github.com/nseilaz/AzureArc_Workbooks](https://github.com/nseilaz/AzureArc_Workbooks)** and are vendored here (not git-submoduled) so the demo deploys are reproducible against a known-good snapshot.

**License:** MIT — see [`LICENSE.upstream`](LICENSE.upstream).
**Credit:** All workbook content authored by [Nic Seilaz](https://github.com/nseilaz).

The asset inventory template's incoming sample subscription/workspace selection
has been cleared for handoff. Deployment binds workspace selectors by their
parameter names/labels to the explicitly targeted demo workspace; no upstream
operator's resource ID should be shipped as a default. Public policy-initiative
lookup constants and required upstream attribution are retained.

## What's in here

| File | Workbook | What it shows |
|---|---|---|
| `Arc_Compliance_Security_Governance_example.json` | Compliance, Security & Governance | Estate inventory, NIST CSF v2 compliance, patch posture, privileged activity, TLS hardening, Defender alerts, configuration drift. Not deployed: the lab publishes the rebuilt `workbooks/arc-compliance.workbook.json`. |
| `ArcMachineIntelligenceCenter.json` | Arc Machine Intelligence Center | 360° view of one Arc machine: live perf, security health, CVSS vulns, software history, SQL (if applicable), Arc mgmt, ops timeline. |
| `Asset_Inventory_Workbook_Example.json` | Asset Inventory | Estate-wide hardware/software inventory roll-up. |
| `GovernanceComplianceWorkbook_Experiment.json` | Governance & Compliance (experimental) | Larger compliance workbook with deeper drill-downs. |
| `SQL_Estate_Dashboard.json` | SQL Estate Dashboard | Arc-enabled SQL inventory + Best Practice Assessment results. |

## Local changes to the vendored snapshot

The deployed copies differ from upstream in small query-text and default-value
ways. Re-apply or re-check them after refreshing the snapshot below, or the
refresh silently reverts them (`tests/OriginalWorkbooks.Tests.ps1` guards them):

- Asset Inventory is no longer deployed from this folder. It is rebuilt in
  `workbooks/arc-asset-inventory.workbook.json` (queries adapted from the upstream file, attribution
  kept in its header); the upstream file stays here unchanged as the attribution snapshot.
- Log Analytics items (tiles, parameters and group members) are pinned to this deployment's workspace by
  Phase 11 at publish (`Set-WorkbookWorkspaceDefaults`), whatever the repo JSON says. The upstream workspace
  pickers resolved in the portal to a second workspace without the Change Tracking tables and showed
  "Failed to resolve table" errors; `tests/WorkbookWorkspaceScope.Tests.ps1` publishes all five upstream-derived
  workbooks with a fake workspace and checks the pin.
- Subscription pickers (Asset Inventory, Compliance, Governance) default to
  **All** (`value::all`), so tiles populate when the workbook opens.
- Tag queries (Asset Inventory, Governance) also read the lab's `costcenter`,
  `owner` and `env` tags. Resource Graph tag names are case-sensitive, so
  `CostCentre`/`Owner`/`Environment` alone reported every machine as untagged.
- Governance: the Governance Health Score tile projects the `Compliant` column its
  tile reads. A few titles and headings that held a replacement character (U+FFFD)
  in Governance and Machine Intelligence Center now carry an emoji.
- Compliance, Security & Governance is no longer deployed from this folder either. It is rebuilt in
  `workbooks/arc-compliance.workbook.json` (attribution kept in its header): posture tiles for Azure Policy,
  Defender secure score, Update Manager patching and the Defender agent, a per-server scorecard, and
  policy, Defender, patch and security-monitoring sections with a specific message on every tile
  (`tests/ComplianceWorkbook.Tests.ps1` guards it). The patch tiles read Update Manager assessments
  (`patchassessmentresources`) instead of the upstream connection-state estimate and report a failed or
  never-assessed machine as such. The upstream file stays here as the snapshot, with the earlier local
  fixes that `tests/OriginalWorkbooks.Tests.ps1` still checks.
- SQL Estate Dashboard: the version and licence charts understand Arc SQL text
  values such as `SQL Server 2022` and `Free`, not only numeric versions. The BPA
  tiles remain explained placeholders because this lab collects no BPA data.

## How they get into your workspace

`scripts/Deploy-ArcDemo.ps1` reads each file, sets `sourceId` to your demo workspace, and PUTs them as shared workbooks in the Arc resource group. Search **Workbooks** and choose the demo group/workspace; the Arc portal navigation can vary.

A vendored workbook is a presentation template, not proof its data sources are
populated. In particular, keep SQL Estate/BPA out of the default Azure-only lab's
validated story; see [SQL stance](../../docs/sql-arc-spike.md).

## Updating the snapshot

To pull the latest from upstream:

```powershell
$dest = '.\workbooks\nseilaz' # Run from the repository root.
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
