BeforeAll {
    $script:fixtureComputerName = 'NESTSQLV2'
    Import-Module (Join-Path $PSScriptRoot '..\scripts\lib\NestedSqlDemo.psm1') -Force
    function ConvertTo-FixtureSecureString {
        param([string]$Text)
        $secure = [securestring]::new()
        foreach ($character in $Text.ToCharArray()) { $secure.AppendChar($character) }
        $secure.MakeReadOnly()
        $secure
    }
}

Describe 'Windows scratch-build answer document' {
    It 'sets only specialize and oobeSystem with correctly escaped XML' {
        $sentinel = 'Synthetic!Credential123456&<>"'
        $secure = ConvertTo-FixtureSecureString $sentinel
        try {
            [xml]$answer = New-NestedSqlAnswerXml -ComputerName $script:fixtureComputerName -AdministratorPassword $secure
            $ns = [Xml.XmlNamespaceManager]::new($answer.NameTable)
            $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
            @($answer.SelectNodes('//u:settings', $ns)).Count | Should -Be 2
            $answer.SelectSingleNode('//u:settings[@pass="specialize"]//u:ComputerName', $ns).InnerText | Should -BeExactly 'NESTSQLV2'
            $answer.SelectSingleNode('//u:settings[@pass="oobeSystem"]//u:HideLocalAccountScreen', $ns).InnerText | Should -BeExactly 'true'
            $answer.SelectSingleNode('//u:settings[@pass="oobeSystem"]//u:AdministratorPassword/u:Value', $ns).InnerText | Should -BeExactly $sentinel
            $answer.OuterXml | Should -Not -Match 'SkipMachineOOBE|SkipUserOOBE|AutoLogon|Reseal|DiskConfiguration|RunSynchronous'
        } finally { $secure.Dispose() }
    }

    It 'explicitly disables the attribute default IgnoreCase option' {
        $attributes = @((Get-Command New-NestedSqlAnswerXml).Parameters['ComputerName'].Attributes |
            Where-Object { $_ -is [Management.Automation.ValidatePatternAttribute] })
        $attributes.Count | Should -Be 1
        [int]$attributes[0].Options | Should -Be 0
        $attributes[0].RegexPattern | Should -BeExactly '\A[A-Za-z][A-Za-z0-9-]{0,13}[A-Za-z0-9]\z'
    }

    It 'rejects Unicode case-fold equivalents in leading, interior and trailing positions' {
        $secure = ConvertTo-FixtureSecureString 'Synthetic!Credential123456'
        try {
            foreach ($value in @(0x212A, 0x0130, 0x0131, 0x017F, 0x212B, 0x00C4, 0x00E4, 0xFF21)) {
                foreach ($name in @("$([char]$value)GUEST", "GUE$([char]$value)T", "GUEST$([char]$value)")) {
                    { New-NestedSqlAnswerXml -ComputerName $name -AdministratorPassword $secure } | Should -Throw
                }
            }
        } finally { $secure.Dispose() }
    }

    It 'rejects leading, embedded and trailing controls, including trailing LF' {
        $secure = ConvertTo-FixtureSecureString 'Synthetic!Credential123456'
        try {
            foreach ($value in @((0..31) + 127 + 133 + 160 + 8232 + 8233)) {
                foreach ($name in @("GUEST$([char]$value)", "$([char]$value)GUEST", "GU$([char]$value)EST")) {
                    { New-NestedSqlAnswerXml -ComputerName $name -AdministratorPassword $secure } | Should -Throw
                }
            }
            foreach ($name in @("GUEST`r`n", "GUEST`n`n", ' GUEST', 'GUEST ', '-GUEST', 'GUEST-', 'guest<xml', 'ABCDEFGHIJKLMNOP')) {
                { New-NestedSqlAnswerXml -ComputerName $name -AdministratorPassword $secure } | Should -Throw
            }
        } finally { $secure.Dispose() }
    }

    It 'accepts exact ASCII name boundaries and both ASCII letter cases' {
        $secure = ConvertTo-FixtureSecureString 'Synthetic!Credential123456'
        try {
            foreach ($name in @('AB', 'A12345678901234', 'Guest-01', 'guest01', 'GUEST01')) {
                [xml]$answer = New-NestedSqlAnswerXml -ComputerName $name -AdministratorPassword $secure
                $answer.OuterXml | Should -Match ([regex]::Escape("<ComputerName>$name</ComputerName>"))
            }
        } finally { $secure.Dispose() }
    }

    It 'rejects controls and non-ASCII in the fresh random credential without returning or echoing it' {
        foreach ($value in @((0..32) + 127 + 133 + 160 + 8232 + 8233 + 0x212A + 0x0130 + 0x0131 + 0x017F)) {
            $sentinel = 'Synthetic!Credential123456' + [char]$value
            $secure = ConvertTo-FixtureSecureString $sentinel
            try {
                $failure = $null
                try { $null = New-NestedSqlAnswerXml -ComputerName $script:fixtureComputerName -AdministratorPassword $secure }
                catch { $failure = $_ }
                $failure | Should -Not -BeNullOrEmpty
                $failure.ToString() | Should -Not -Match 'Synthetic!Credential'
            } finally { $secure.Dispose() }
        }
    }

    It 'enforces password length and complexity without echoing the synthetic value' {
        foreach ($sentinel in @('Short1!', ('A' * 129), 'abcdefghijklmnopqrstuvwxyz123456',
            'ABCDEFGHIJKLMNOPQRSTUVWXYZ123456', 'SyntheticCredentialNoDigits!', 'SyntheticCredentialNoSymbol123')) {
            $secure = ConvertTo-FixtureSecureString $sentinel
            try {
                $failure = $null
                try { $null = New-NestedSqlAnswerXml -ComputerName $script:fixtureComputerName -AdministratorPassword $secure }
                catch { $failure = $_ }
                $failure | Should -Not -BeNullOrEmpty
                $failure.ToString() | Should -Not -Match ([regex]::Escape($sentinel))
            } finally { $secure.Dispose() }
        }
    }
}
