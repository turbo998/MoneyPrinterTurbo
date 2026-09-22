#requires -Version 7.2
[CmdletBinding()]
param()
. "$PSScriptRoot\Azure-Common.ps1"
Assert-AzureContext
$outputs = Get-BootstrapOutputs
$network = Get-PrivateNetworkStatus $outputs
$subscription = Get-RequiredEnvironment AZURE_SUBSCRIPTION_ID
$tenant = Get-RequiredEnvironment MPT_TENANT_ID
$clientId = Get-RequiredEnvironment MPT_ENTRA_CLIENT_ID
$allowed = Get-ObjectIdAllowlist
$resourceGroup = $outputs.AZURE_RESOURCE_GROUP
$name = $outputs.MPT_WEB_APP_NAME
$appPath = "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.App/containerApps/$name"

function Assert-LiveAuthorization {
    $auth = (Invoke-Arm "$appPath/authConfigs/current?api-version=2025-01-01").properties |
        ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable
    $aad = $auth.identityProviders.azureActiveDirectory
    if (-not $auth.platform.enabled -or -not $aad.enabled -or -not $auth.httpSettings.requireHttps -or
        $auth.globalValidation.unauthenticatedClientAction -ne 'RedirectToLoginPage' -or
        $auth.globalValidation.redirectToProvider -ne 'azureActiveDirectory' -or
        @($auth.globalValidation['excludedPaths'] | Where-Object { $_ }).Count -ne 0 -or
        $aad.registration.openIdIssuer.TrimEnd('/') -ne "https://login.microsoftonline.com/$tenant/v2.0" -or
        $aad.registration.clientId -ne $clientId -or
        $aad.registration.clientSecretSettingName -ne 'entra-client-secret') {
        throw 'Live EasyAuth settings are missing or not the expected fail-closed single-tenant configuration.'
    }
    $liveAllowed = @($aad.validation.defaultAuthorizationPolicy.allowedPrincipals.identities |
        ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    if (Compare-Object $allowed $liveAllowed) { throw 'Live EasyAuth object-ID allowlist differs from MPT_ALLOWED_OIDS.' }
    $policy = $aad.validation.defaultAuthorizationPolicy
    if (@($policy.allowedPrincipals['groups'] | Where-Object { $_ }).Count -ne 0 -or
        @($policy['allowedApplications'] | Where-Object { $_ }).Count -ne 0) {
        throw 'Unexpected group or application authorization policy.'
    }
    foreach ($audience in $aad.validation.allowedAudiences) {
        if ($audience -notin @($clientId, "api://$clientId")) { throw 'Unexpected accepted token audience.' }
    }
    foreach ($providerName in $auth.identityProviders.Keys) {
        $provider = $auth.identityProviders[$providerName]
        if ($providerName -eq 'customOpenIdConnectProviders' -and $provider -and $provider.Count -gt 0) {
            throw 'Unexpected custom authentication provider.'
        }
        if ($providerName -ne 'azureActiveDirectory' -and $provider -and $provider['enabled']) {
            throw 'Unexpected additional authentication provider.'
        }
    }
}

# Close an existing public deployment before validating policy changes.
Invoke-Az @('containerapp', 'ingress', 'enable', '--name', $name, '--resource-group', $resourceGroup,
    '--type', 'internal', '--target-port', '8501', '--allow-insecure', 'false', '--output', 'none')
Assert-LiveAuthorization
$publicHost = ([uri]$network.PublicUrl).Host
$callback = $network.Callback
$registration = (Invoke-Az @('ad', 'app', 'show', '--id', $clientId, '--output', 'json')) | ConvertFrom-Json
if ($registration.signInAudience -ne 'AzureADMyOrg' -or $callback -notin $registration.web.redirectUris) {
    throw "App registration must be single tenant and have Web redirect URI $callback"
}
try {
    Invoke-Az @('containerapp', 'ingress', 'enable', '--name', $name, '--resource-group', $resourceGroup,
        '--type', 'external', '--target-port', '8501', '--transport', 'auto',
        '--allow-insecure', 'false', '--output', 'none')
    Assert-LiveAuthorization
    Start-Sleep -Seconds 20
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $http = [Net.Http.HttpClient]::new($handler)
    $http.Timeout = [TimeSpan]::FromSeconds(60)
    foreach ($path in @('/', '/media/auth-probe.mp4', '/_stcore/download/auth-probe',
            '/_stcore/stream', '/_stcore/health')) {
        $response = $http.GetAsync("https://$publicHost$path").GetAwaiter().GetResult()
        try {
            $status = [int]$response.StatusCode
            $redirect = [string]$response.Headers.Location
            $blocked = $status -in @(401, 403) -or
                ($status -in @(302, 303, 307) -and
                    ($redirect.StartsWith('/.auth/login/') -or
                    $redirect.StartsWith("https://$publicHost/.auth/login/") -or
                    $redirect.StartsWith("https://login.microsoftonline.com/$tenant/")))
            if (-not $blocked) { throw "Anonymous route $path was not blocked by authentication (HTTP $status)." }
        }
        finally { $response.Dispose() }
    }
    $app = Invoke-Arm "$appPath`?api-version=2025-01-01"
    if ($app.properties.configuration.ingress.allowInsecure -or
        $app.properties.configuration.ingress.targetPort -ne 8501) { throw 'Ingress is not HTTPS-only on the UI port.' }
}
catch {
    Invoke-Az @('containerapp', 'ingress', 'enable', '--name', $name, '--resource-group', $resourceGroup,
        '--type', 'internal', '--target-port', '8501', '--allow-insecure', 'false', '--output', 'none')
    throw
}
finally {
    if (Get-Variable http -ErrorAction SilentlyContinue) { $http.Dispose() }
    if (Get-Variable handler -ErrorAction SilentlyContinue) { $handler.Dispose() }
}
Write-Host "Published https://$publicHost with anonymous routes denied. Authorized/unauthorized-user browser tests are still required."
