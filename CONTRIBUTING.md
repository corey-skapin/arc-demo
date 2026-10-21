# Contributing

Pull requests welcome. Quick rules:

1. Read [`AGENTS.md`](AGENTS.md) first — it captures all the gotchas the scripts work around. Don't undo those workarounds.
2. Lint passes locally before pushing:

   ```powershell
   Invoke-ScriptAnalyzer -Path .\scripts\ -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
   Invoke-Pester -Path .\tests -CI
   az bicep build --file .\bicep\main.bicep --stdout > $null
   ```

3. If you hit a new failure mode, **add it to [`docs/troubleshooting.md`](docs/troubleshooting.md)** in the same PR with a verified fix.
4. Scripts must remain **idempotent** — preserve correct state, credentials and fault flags on rerun. Start with mocked tests; real double deployment requires a separately approved disposable lab, never an in-use demo.
5. Bicep modules go in `bicep/modules/`; top-level template stays in `bicep/main.bicep`.
6. Keep `Common.psm1` lean — only put a helper there if it's used in 2+ scripts.
7. Keep real customer labels, contacts, owner repository URLs, runtime identifiers,
   credentials and evidence outside tracked source. Use synthetic examples and
   runtime parameters; preserve public Azure built-in IDs and upstream licenses.

## Testing changes

Run the existing parser/Pester/analyzer/Bicep checks first. Documentation is
linted in CI, but the Markdown job is advisory; inspect its actual output.
If live smoke testing is explicitly approved, use a disposable prefix and the
same confirmed target/skin throughout:

```powershell
$target = @{ SubscriptionId = '<SUB>'; TenantId = '<TENANT>'; NamePrefix = 'arctest'; SkinPath = '.\config\demo-skin.json' }
.\scripts\Deploy-ArcDemo.ps1 @target -AdminEmail <EMAIL> -WhatIf
.\scripts\Deploy-ArcDemo.ps1 @target -AdminEmail <EMAIL>
# ... verify in portal ...
.\scripts\Test-ArcDemoReadiness.ps1 @target -DesiredState Ready -OutputFormat Json
.\scripts\Hibernate-ArcDemo.ps1 @target
.\scripts\Test-ArcDemoReadiness.ps1 @target -DesiredState Hibernated -OutputFormat Json
.\scripts\Activate-ArcDemo.ps1 @target
.\scripts\Remove-ArcDemo.ps1 @target -WhatIf
# Execute removal only under the separately approved destructive-test scope.
```

Reprice runtime, storage, networking and retained services; no fixed smoke-test
cost is guaranteed. See [cost.md](docs/cost.md) and [lifecycle.md](docs/lifecycle.md).

## Reporting issues

Use `.github/ISSUE_TEMPLATE/bug.md`. Include the smallest useful error/reproduction
excerpt; redact credentials, tokens, onboarding payloads, private IDs and mailboxes.
