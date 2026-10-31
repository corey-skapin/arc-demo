#Requires -Version 5.1
param(
    [Parameter(Mandatory)][string]$ActorPath,
    [Parameter(Mandatory)][ValidateSet('ActualHandshake', 'Authentication', 'Socket', 'Timeout', 'LongChain', 'Unknown')][string]$Case,
    [ValidateSet('RuntimeDefault', 'Tls12')][string]$TlsMode = 'RuntimeDefault'
)
$ErrorActionPreference = 'Stop'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($ActorPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw 'TLS fixture actor did not parse.' }
$top = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
$tls = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.TryStatementAst] -and
    @($node.Body.Statements | Where-Object {
        $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$authentication'
    }).Count -eq 1
}, $true))
$timeout = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Clauses[0].Item1.Extent.Text -eq '-not $authentication.Wait(10000)'
}, $true))
if ($top.Count -ne 1 -or $tls.Count -ne 1 -or $timeout.Count -ne 1) { throw 'TLS fixture expected exact actor AST boundaries.' }
$body = $top[0].CatchClauses[0].Body.Extent.Text
$failureBlock = [scriptblock]::Create($body.Substring(1, $body.Length - 2))
$tlsBlock = [scriptblock]::Create($tls[0].Extent.Text)
$timeoutBlock = [scriptblock]::Create($timeout[0].Extent.Text)
$stage = 'private-tls'; $reason = 'tls-authentication-failed'
$Operation = 'Marker'
$details = @{ tlsPhase = 'authenticate-wait' }
$authentication = $null
$dnsName = 'kv-fixture.vault.azure.net'
$memory = $null
$script:caught = $false
$watch = [Diagnostics.Stopwatch]::StartNew()
$output = @(. {
    try {
        switch ($Case) {
            ActualHandshake {
                # The actual actor TLS block runs on a memory stream, never a socket.
                $memory = [IO.MemoryStream]::new()
                $ssl = [Net.Security.SslStream]::new($memory, $false)
                . $tlsBlock
            }
            Authentication {
                $inner = [ComponentModel.Win32Exception]::new(-2146893019)
                $exception = [Security.Authentication.AuthenticationException]::new('SENSITIVE_SENTINEL', $inner)
                $authentication = [Threading.Tasks.Task]::FromException($exception)
                $authentication.Wait(10000) | Out-Null
            }
            Socket {
                $authentication = [Threading.Tasks.Task]::FromException([Net.Sockets.SocketException]::new(10054))
                $authentication.Wait(10000) | Out-Null
            }
            Timeout {
                $authentication = [Threading.Tasks.TaskCompletionSource[bool]]::new().Task
                . $timeoutBlock
            }
            LongChain {
                $exception = [Exception]::new('SENSITIVE_SENTINEL')
                for ($i = 0; $i -lt 12; $i++) { $exception = [Exception]::new('SENSITIVE_SENTINEL', $exception) }
                throw $exception
            }
            Unknown { throw [Exception]::new('SENSITIVE_SENTINEL') }
        }
    } catch {
        try { . $failureBlock }
        catch {
            $script:caught = $true
            $script:failureKind = $_.Exception.GetType().Name
            $script:failureLine = $_.InvocationInfo.ScriptLineNumber
        }
    }
})
$watch.Stop()
$failure = $null
foreach ($line in $output) {
    if ($line -match '^ARC_PRIVATE_VAULT_FAILURE:(\{.*\})$') { $failure = $Matches[1] | ConvertFrom-Json }
}
if (-not $script:caught -or -not $failure) { throw "TLS fixture expected sanitized terminal failure (kind=$script:failureKind, line=$script:failureLine, output=$($output.Count))." }
[ordered]@{
    psVersion = "$($PSVersionTable.PSVersion)"
    failure = $failure
    elapsedMilliseconds = $watch.ElapsedMilliseconds
    clientHelloTls12 = $(if ($memory) {
        $hello = $memory.ToArray()
        $hello.Length -gt 11 -and $hello[0] -eq 22 -and $hello[5] -eq 1 -and $hello[9] -eq 3 -and $hello[10] -eq 3
    } else { $false })
    clientHelloContainsHostname = $(if ($memory) { [Text.Encoding]::ASCII.GetString($memory.ToArray()).Contains($dnsName) } else { $false })
} | ConvertTo-Json -Depth 8 -Compress
