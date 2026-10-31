#Requires -Version 5.1
param(
    [Parameter(Mandatory)][string]$ActorPath,
    [Parameter(Mandatory)][ValidateSet('Success', 'Denied', 'Redirect', 'ForeignRoute')][string]$Case
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
$before = [Net.ServicePointManager]::SecurityProtocol
$real = [Net.Http.HttpClientHandler]::new()
try {
    $real.SslProtocols = [Security.Authentication.SslProtocols]::Tls12
    $real.AllowAutoRedirect = $false
    $actualProtocols = [int]$real.SslProtocols
    $actualValidationDefault = $null -eq $real.ServerCertificateCustomValidationCallback
    $actualRedirects = $real.AllowAutoRedirect
} finally { $real.Dispose() }
Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Security.Authentication;
public sealed class ArcPrivateHttpFixtureHandler : HttpMessageHandler {
    public SslProtocols SslProtocols { get; set; }
    public bool AllowAutoRedirect { get; set; }
    public static int Calls;
    public static int Code = 200;
    public static bool HeaderCorrect;
    public static bool RouteCorrect;
    public static bool PolicyCorrect;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
        Calls++;
        HeaderCorrect = request.Headers.Authorization != null &&
            request.Headers.Authorization.Scheme == "Bearer" &&
            request.Headers.Authorization.Parameter == "SENSITIVE_SENTINEL";
        RouteCorrect = request.RequestUri.AbsoluteUri == "https://kv-fixture.vault.azure.net/secrets/arc-onboarding-client-secret?api-version=7.4";
        PolicyCorrect = SslProtocols == SslProtocols.Tls12 && !AllowAutoRedirect;
        var response = new HttpResponseMessage((HttpStatusCode)Code);
        response.Content = new StringContent("{\"value\":\"SENSITIVE_SENTINEL\"}");
        return Task.FromResult(response);
    }
}
'@
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($ActorPath, [ref]$tokens, [ref]$errors)
$functions = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-PrivateVaultRequest' }, $true))
if ($errors -or $functions.Count -ne 1) { throw 'Private HTTP fixture expected one parsed helper.' }
$original = '$handler = [Net.Http.HttpClientHandler]::new()'
if (-not $functions[0].Extent.Text.Contains($original)) { throw 'Private HTTP fixture expected exact transport seam.' }
# Only the network handler is synthetic; HttpClient/request/content/disposal are real.
. ([scriptblock]::Create($functions[0].Extent.Text.Replace($original, '$handler = [ArcPrivateHttpFixtureHandler]::new()')))
$TlsMode = 'Tls12'; $VaultName = 'kv-fixture'; $SecretName = 'arc-onboarding-client-secret'
$uri = 'https://kv-fixture.vault.azure.net/secrets/arc-onboarding-client-secret?api-version=7.4'
if ($Case -eq 'Denied') { [ArcPrivateHttpFixtureHandler]::Code = 403 }
if ($Case -eq 'Redirect') { [ArcPrivateHttpFixtureHandler]::Code = 302 }
if ($Case -eq 'ForeignRoute') { $uri = 'https://foreign.invalid/secrets/other?api-version=7.4' }
$code = 0; $failed = $false; $verified = $false; $safeError = $true
try {
    $value = Invoke-PrivateVaultRequest -Method PUT -Uri $uri -Headers @{ Authorization = 'Bearer SENSITIVE_SENTINEL' } -Body '{"value":"SENSITIVE_SENTINEL"}'
    $verified = $value.value -ceq 'SENSITIVE_SENTINEL'
} catch {
    $failed = $true
    $safeError = $_.Exception.Message -notmatch 'SENSITIVE_SENTINEL'
    if ($_.Exception.Data.Contains('ArcPrivateHttpStatus')) { $code = [int]$_.Exception.Data['ArcPrivateHttpStatus'] }
} finally { $value = $null }
[ordered]@{
    psVersion = "$($PSVersionTable.PSVersion)"
    realProtocols = $actualProtocols; realValidationDefault = $actualValidationDefault
    realRedirects = $actualRedirects; globalProtocolUnchanged = ($before -eq [Net.ServicePointManager]::SecurityProtocol)
    calls = [ArcPrivateHttpFixtureHandler]::Calls
    routeCorrect = [ArcPrivateHttpFixtureHandler]::RouteCorrect
    policyCorrect = [ArcPrivateHttpFixtureHandler]::PolicyCorrect
    headerCorrect = [ArcPrivateHttpFixtureHandler]::HeaderCorrect
    failed = $failed; httpStatus = $code; valueVerified = $verified; safeError = $safeError
} | ConvertTo-Json -Compress
