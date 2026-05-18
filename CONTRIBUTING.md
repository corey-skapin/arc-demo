# Contributing

Pull requests welcome. Quick rules:

1. Read [`AGENTS.md`](AGENTS.md) first — it captures all the gotchas the scripts work around. Don't undo those workarounds.
2. Lint passes locally before pushing:
   ```powershell
   Invoke-ScriptAnalyzer -Path .\scripts\ -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
   az bicep build --file .\bicep\main.bicep --stdout > $null
   ```
3. If you hit a new failure mode, **add it to [`docs/troubleshooting.md`](docs/troubleshooting.md)** in the same PR with a verified fix.
4. Scripts must remain **idempotent** — running them twice in a row should be a no-op against an already-correct state. Test with a real deploy.
5. Bicep modules go in `bicep/modules/`; top-level template stays in `bicep/main.bicep`.
6. Keep `Common.psm1` lean — only put a helper there if it's used in 2+ scripts.

## Testing changes

The cheapest reliable test is to deploy into a temp prefix:
```powershell
.\scripts\Deploy-ArcDemo.ps1 -NamePrefix arctest -SubscriptionId ... -TenantId ... -AdminEmail ...
# ... verify in portal ...
.\scripts\Hibernate-ArcDemo.ps1 -NamePrefix arctest
.\scripts\Activate-ArcDemo.ps1 -NamePrefix arctest
.\scripts\Remove-ArcDemo.ps1 -NamePrefix arctest
```

Total cost of a smoke test: ~AUD 5 if you tear it down within a few hours.

## Reporting issues

Use the bug template at `.github/ISSUE_TEMPLATE/bug.md`. Include the full PowerShell error transcript — redact tenant/sub IDs if needed.
