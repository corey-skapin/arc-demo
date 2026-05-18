@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # We intentionally use Write-Host for human-readable progress banners.
        # All scripts here are interactive demos, not pipeline-targeted cmdlets.
        'PSAvoidUsingWriteHost',

        # Start-Job here uses -ArgumentList for cross-process variable passing,
        # which is the correct pattern. The $using: modifier doesn't apply.
        'PSUseUsingScopeModifierInNewRunspaces',

        # Verb-Noun functions returning derived values (New-StrongPassword,
        # New-KeyVaultName) aren't state-changing.
        'PSUseShouldProcessForStateChangingFunctions',

        # "Prerequisites" is the noun, not a plural of "Prerequisite".
        'PSUseSingularNouns',

        # We write UTF-8 deliberately without BOM (cross-platform friendly).
        'PSUseBOMForUnicodeEncodedFile'
    )
}
