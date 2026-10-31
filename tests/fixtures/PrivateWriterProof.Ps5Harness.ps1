#Requires -Version 5.1
param([string]$ActorPath, [ValidateSet('Marker', 'Initialize')][string]$Operation)
$ErrorActionPreference = 'Stop'
$stored = @{ id = 'https://kv-fixture.vault.azure.net/secrets/arc-onboarding-client-secret/123456789012345678901234567890ab' }
$resolved = @('10.50.1.10')
$ExpiresAtUtc = if ($Operation -eq 'Initialize') { [datetimeoffset]::UtcNow.AddDays(30).ToString('o') } else { '' }
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($ActorPath, [ref]$tokens, [ref]$errors)
$assignment = @($ast.FindAll({
    param($n)
    $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$receipt'
}, $true))
if ($errors -or $assignment.Count -ne 1) { throw 'Expected exactly one actual private writer receipt expression.' }
# Execute the exact producer assignment under PS5, not a controller-shaped mock.
. ([scriptblock]::Create($assignment[0].Extent.Text))
'ARC_PRIVATE_VAULT_RESULT:' + ($receipt | ConvertTo-Json -Depth 4 -Compress)
