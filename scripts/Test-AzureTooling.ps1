#requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$testState = @{ Checks = 0; BuildObserved = $false; ContextPath = '' }

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $testState.Checks++
}

# Extract only the pure authorization guard: never execute the publishing script.
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'Publish-Azure.ps1'), [ref]$tokens, [ref]$errors)
$guard = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Assert-LiveAuthorization'
}, $true)
. ([ScriptBlock]::Create($guard.Extent.Text))
$appPath = '/offline-test'
$tenant = '11111111-1111-1111-1111-111111111111'
$clientId = '22222222-2222-2222-2222-222222222222'
$allowed = @('33333333-3333-3333-3333-333333333333')
$baseline = @{
    platform = @{ enabled = $true }
    httpSettings = @{ requireHttps = $true }
    globalValidation = @{
        unauthenticatedClientAction = 'RedirectToLoginPage'
        redirectToProvider = 'azureActiveDirectory'
        excludedPaths = @()
    }
    identityProviders = @{
        azureActiveDirectory = @{
            enabled = $true
            registration = @{
                openIdIssuer = "https://login.microsoftonline.com/$tenant/v2.0"
                clientId = $clientId
                clientSecretSettingName = 'entra-client-secret'
            }
            validation = @{
                allowedAudiences = @($clientId, "api://$clientId")
                defaultAuthorizationPolicy = @{
                    allowedPrincipals = @{ identities = $allowed }
                }
            }
        }
    }
}
function Invoke-Arm {
    param([string]$ResourcePath)
    return @{ properties = $script:policy }
}
function Reset-Policy {
    $script:policy = $baseline | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
}
function Assert-PolicyRejected {
    $denied = $false
    try { Assert-LiveAuthorization } catch { $denied = $true }
    Assert-Test $denied 'An unsafe live authentication configuration was accepted.'
}
Reset-Policy
Assert-LiveAuthorization
Assert-Test $true 'Baseline authorization should pass.'
Reset-Policy
$policy.globalValidation.Remove('excludedPaths')
Assert-LiveAuthorization
Assert-Test $true 'An omitted empty excludedPaths field should pass.'
Reset-Policy
$policy.globalValidation.excludedPaths = $null
$policy.identityProviders.customOpenIdConnectProviders = $null
$policy.identityProviders.google = $null
Assert-LiveAuthorization
Assert-Test $true 'Null optional provider/path fields should pass.'
Reset-Policy
$policy.platform.enabled = $false
Assert-PolicyRejected
Reset-Policy
$policy.globalValidation.excludedPaths = @('/media/*')
Assert-PolicyRejected
Reset-Policy
$policy.globalValidation.unauthenticatedClientAction = 'AllowAnonymous'
Assert-PolicyRejected
Reset-Policy
$policy.identityProviders.azureActiveDirectory.registration.openIdIssuer = 'https://login.microsoftonline.com/common/v2.0'
Assert-PolicyRejected
Reset-Policy
$policy.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals.identities = @()
Assert-PolicyRejected
Reset-Policy
$policy.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals.groups = @('group')
Assert-PolicyRejected
Reset-Policy
$policy.identityProviders.azureActiveDirectory.validation.allowedAudiences += 'untrusted-audience'
Assert-PolicyRejected
Reset-Policy
$policy.identityProviders.google = @{ enabled = $true }
Assert-PolicyRejected

# Validate actual compiled resource references, then break individual bindings.
$validationAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'Validate-Azure.ps1'), [ref]$tokens, [ref]$errors)
foreach ($functionName in @('Assert-Contract', 'Assert-PrivateNetworkTemplate')) {
    $definition = $validationAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    . ([ScriptBlock]::Create($definition.Extent.Text))
}
$compiled = az bicep build --file (Join-Path $root 'infra\main.bicep') --stdout --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Offline Bicep compilation failed.' }
$template = $compiled | ConvertFrom-Json -AsHashtable
Assert-PrivateNetworkTemplate $template
Assert-Test $true 'Compiled private network should pass.'
foreach ($case in @(
    @{ Name = 'PE target'; Change = { param($n) $n.Endpoint.properties.privateLinkServiceConnections[0].properties.privateLinkServiceId = '/wrong-account' } },
    @{ Name = 'PE group'; Change = { param($n) $n.Endpoint.properties.privateLinkServiceConnections[0].properties.groupIds = @('file') } },
    @{ Name = 'PE subnet'; Change = { param($n) $n.Endpoint.properties.subnet.id = '/aca-infrastructure' } },
    @{ Name = 'Missing service'; Change = { param($n) $n.Network.variables.services = @('blob', 'queue') } },
    @{ Name = 'Missing DNS loop'; Change = { param($n) $n.Link.copy.count = 1 } },
    @{ Name = 'DNS link target'; Change = { param($n) $n.Link.properties.virtualNetwork.id = '/wrong-vnet' } },
    @{ Name = 'DNS registration'; Change = { param($n) $n.Link.properties.registrationEnabled = $true } },
    @{ Name = 'DNS group target'; Change = { param($n) $n.Group.properties.privateDnsZoneConfigs[0].properties.privateDnsZoneId = '/wrong-zone' } },
    @{ Name = 'ACA subnet delegation'; Change = { param($n) $n.Vnet.properties.subnets[0].properties.delegations[0].properties.serviceName = 'Microsoft.Web/serverFarms' } },
    @{ Name = 'ACA subnet range'; Change = { param($n) $n.Vnet.properties.subnets[0].properties.addressPrefix = '10.247.2.0/27' } },
    @{ Name = 'Environment subnet binding'; Change = { param($n) $n.Environment.properties.vnetConfiguration.infrastructureSubnetId = '/wrong-subnet' } },
    @{ Name = 'Legacy environment'; Change = { param($n) $n.Environment.name = "[format('{0}-env', variables('stem'))]" } },
    @{ Name = 'Legacy app output'; Change = { param($n) $n.Foundation.outputs.webAppName.value = "[format('{0}-web', variables('stem'))]" } },
    @{ Name = 'Public Storage'; Change = { param($n) $n.Storage.properties.publicNetworkAccess = 'Enabled' } },
    @{ Name = 'Shared Key'; Change = { param($n) $n.Storage.properties.allowSharedKeyAccess = $true } }
)) {
    $broken = $template | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    $foundation = @($broken.resources | Where-Object { $_.name -like '*foundation*' })[0].properties.template
    $network = @($foundation.resources | Where-Object name -EQ 'private-network')[0].properties.template
    $nodes = @{
        Foundation = $foundation; Network = $network
        Environment = @($foundation.resources | Where-Object type -EQ 'Microsoft.App/managedEnvironments')[0]
        Storage = @(@($foundation.resources | Where-Object name -EQ 'storage')[0].properties.template.resources |
            Where-Object type -EQ 'Microsoft.Storage/storageAccounts')[0]
        Vnet = @($network.resources | Where-Object type -EQ 'Microsoft.Network/virtualNetworks')[0]
        Endpoint = @($network.resources | Where-Object type -EQ 'Microsoft.Network/privateEndpoints')[0]
        Link = @($network.resources | Where-Object type -EQ 'Microsoft.Network/privateDnsZones/virtualNetworkLinks')[0]
        Group = @($network.resources | Where-Object type -EQ 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups')[0]
    }
    & $case.Change $nodes
    $denied = $false
    try { Assert-PrivateNetworkTemplate $broken } catch { $denied = $true }
    Assert-Test $denied "Compiled network accepted: $($case.Name)."
}

# Run remote-build packaging with a local CLI stub; no Azure calls or image build.
$savedEnvironment = @{}
foreach ($key in @('AZURE_SUBSCRIPTION_ID', 'MPT_TENANT_ID', 'MPT_BOOTSTRAP_DEPLOYMENT', 'MPT_CONTAINER_IMAGE')) {
    $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
}
$env:AZURE_SUBSCRIPTION_ID = '44444444-4444-4444-4444-444444444444'
$env:MPT_TENANT_ID = $tenant
$env:MPT_BOOTSTRAP_DEPLOYMENT = 'offline-bootstrap'
function az {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'account' -and $args[1] -eq 'show') {
        return (@{ id = $env:AZURE_SUBSCRIPTION_ID; tenantId = $env:MPT_TENANT_ID } | ConvertTo-Json)
    }
    if ($args[0] -eq 'account' -and $args[1] -eq 'get-access-token') {
        return 'token-secret-sentinel'
    }
    if ($args[0] -eq 'deployment') {
        if ($testState['BootstrapOutputs']) {
            $result = @{}
            foreach ($key in $testState.BootstrapOutputs.Keys) { $result[$key] = @{ value = $testState.BootstrapOutputs[$key] } }
            return ($result | ConvertTo-Json -Depth 10)
        }
        return (@{
            AZURE_CONTAINER_REGISTRY_NAME = @{ value = 'offlineacr' }
            AZURE_CONTAINER_REGISTRY_ENDPOINT = @{ value = 'offlineacr.azurecr.io' }
        } | ConvertTo-Json)
    }
    if ($args[0] -eq 'acr' -and $args[1] -eq 'build') {
        $testState.ContextPath = [string]@($args | Where-Object {
            $_ -is [string] -and $_.Contains('.azure-build-')
        })[0]
        $contextPath = $testState.ContextPath
        Assert-Test (Test-Path (Join-Path $contextPath 'Dockerfile.azure')) 'Dockerfile missing from build context.'
        Assert-Test (Test-Path (Join-Path $contextPath 'uv.lock')) 'Frozen lockfile missing from build context.'
        foreach ($forbidden in @('.git', '.venv', '.azure', 'storage', 'config.toml', 'resource\fonts', 'resource\songs')) {
            Assert-Test (-not (Test-Path (Join-Path $contextPath $forbidden))) "Forbidden upload: $forbidden"
        }
        Assert-Test ('linux/amd64' -in $args) 'Remote build architecture is not fixed.'
        $testState.BuildObserved = $true
        return
    }
    if ($args[0] -eq 'acr' -and $args[1] -eq 'repository') { return ('sha256:' + ('a' * 64)) }
    throw 'Unexpected CLI invocation in offline test.'
}
try {
    & "$PSScriptRoot\Build-AzureImage.ps1" -Tag 'offline-contract-test'
    Assert-Test $testState.BuildObserved 'Remote-build invocation was not reached.'
    Assert-Test (-not (Test-Path $testState.ContextPath)) 'Build staging was not cleaned up.'
    Assert-Test ($env:MPT_CONTAINER_IMAGE -eq ('offlineacr.azurecr.io/moneyprinterturbo@sha256:' + ('a' * 64))) 'Image digest was not persisted into this shell.'
}
finally {
    foreach ($key in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key])
    }
}

# Exercise the real ARM helper with HTTP/token stubs, including failure redaction.
. "$PSScriptRoot\Azure-Common.ps1"
function Invoke-RestMethod {
    [CmdletBinding()]
    param([string]$Uri, [string]$Method, [hashtable]$Headers, [string]$ContentType, [string]$Body)
    $testState.ArmRequest = @{ Uri = $Uri; Method = $Method; Body = $Body }
    if ($testState.ArmMode -eq 'Success') { return @{ accepted = $true } }
    if ($testState.ArmMode -eq 'TransportError') {
        throw [Net.Http.HttpRequestException]::new('response-secret-sentinel')
    }
    $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$testState.ArmStatus)
    $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new('response-secret-sentinel', $response)
    $record = [Management.Automation.ErrorRecord]::new(
        $exception, 'OfflineArmFailure', [Management.Automation.ErrorCategory]::InvalidOperation, $null)
    $record.ErrorDetails = [Management.Automation.ErrorDetails]::new($testState.ArmResponse)
    $PSCmdlet.ThrowTerminatingError($record)
}
$testState.ArmMode = 'Success'
$armResult = Invoke-Arm -ResourcePath '/offline-test?api-version=test' -Method POST `
    -Body @{ credential = 'request-secret-sentinel' }
Assert-Test $armResult.accepted 'Successful ARM responses must be returned unchanged.'
Assert-Test ($testState.ArmRequest.Uri -eq 'https://management.azure.com/offline-test?api-version=test') 'ARM resource paths must receive exactly one endpoint prefix.'
Assert-Test ($testState.ArmRequest.Method -eq 'POST' -and
    $testState.ArmRequest.Body.Contains('request-secret-sentinel')) 'ARM request method/body forwarding changed.'

foreach ($case in @(
    @{ Status = 400; Body = '{"error":{"code":"InvalidParameterValueInContainerTemplate","message":"response-secret-sentinel"}}'; Code = 'InvalidParameterValueInContainerTemplate' },
    @{ Status = 403; Body = '{"error":{"code":"AuthorizationFailed","message":"response-secret-sentinel"}}'; Code = 'AuthorizationFailed' },
    @{ Status = 429; Body = '{"error":{"code":"TooManyRequests","message":"response-secret-sentinel"}}'; Code = 'TooManyRequests' },
    @{ Status = 502; Body = '<html>response-secret-sentinel</html>'; Code = 'UnparseableErrorResponse' },
    @{ Status = 400; Body = '{"error":{"code":"invalid response-secret-sentinel\nvalue"}}'; Code = 'UnspecifiedServiceError' },
    @{ Status = 400; Body = '{"error":{"code":42,"message":"response-secret-sentinel"}}'; Code = 'UnspecifiedServiceError' },
    @{ Status = 500; Body = '{"message":"response-secret-sentinel"}'; Code = 'UnspecifiedServiceError' }
)) {
    $testState.ArmMode = 'HttpError'
    $testState.ArmStatus = $case.Status
    $testState.ArmResponse = $case.Body
    $failureMessage = ''
    try { $null = Invoke-Arm '/offline-test' -Method POST -Body @{ credential = 'request-secret-sentinel' } }
    catch { $failureMessage = $_.Exception.Message }
    Assert-Test ($failureMessage.Contains("HTTP $($case.Status); code $($case.Code)")) 'ARM failures must identify HTTP status and a safe error code.'
    Assert-Test ($failureMessage -notmatch '(request|response|token)-secret-sentinel') 'ARM diagnostics leaked sensitive request/response/token data.'
}
$testState.ArmMode = 'TransportError'
$failureMessage = ''
try { $null = Invoke-Arm '/offline-test' } catch { $failureMessage = $_.Exception.Message }
Assert-Test ($failureMessage.Contains('HTTP unavailable; code NoHttpResponse')) 'Transport failures must be explicit without inventing an HTTP result.'
Assert-Test ($failureMessage -notmatch 'response-secret-sentinel') 'Transport exception text must not be exposed.'

$testState.ArmMode = 'HttpError'
$testState.ArmStatus = 404
$testState.ArmResponse = '{"error":{"code":"ResourceNotFound","message":"response-secret-sentinel"}}'
Assert-Test ($null -eq (Invoke-Arm '/new-app-only' -AllowNotFound)) 'An explicit new-app existence check may accept HTTP 404.'
$failureMessage = ''
try { $null = Invoke-Arm '/new-app-only' } catch { $failureMessage = $_.Exception.Message }
Assert-Test ($failureMessage.Contains('HTTP 404; code ResourceNotFound')) 'Ordinary ARM calls must still fail on HTTP 404.'
$testState.ArmStatus = 403
$failureMessage = ''
try { $null = Invoke-Arm '/new-app-only' -AllowNotFound } catch { $failureMessage = $_.Exception.Message }
Assert-Test ($failureMessage.Contains('HTTP 403')) 'Existence checks must not mistake authorization failure for absence.'
$failureMessage = ''
try { $null = Invoke-Arm '/new-app-only' -Method POST -AllowNotFound } catch { $failureMessage = $_.Exception.Message }
Assert-Test ($failureMessage -like '-AllowNotFound is only valid*') 'Mutation requests must not suppress HTTP 404.'

# Only read-only ARM fixtures are accepted while testing network preflights.
function Invoke-Arm {
    param([string]$ResourcePath, [string]$Method = 'GET', [object]$Body)
    if ($Method -ne 'GET') { throw 'Network preflight must never mutate Azure.' }
    $resourceId = $ResourcePath.Split('?')[0]
    if (-not $testState.NetworkResources.ContainsKey($resourceId)) { throw "Unexpected offline network lookup: $resourceId" }
    return $testState.NetworkResources[$resourceId]
}
$networkEnvironment = @{}
foreach ($key in @('AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'AZURE_ENV_NAME', 'AZURE_LOCATION',
    'MPT_TENANT_ID', 'MPT_BOOTSTRAP_DEPLOYMENT')) {
    $networkEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
}
try {
    $env:AZURE_SUBSCRIPTION_ID = '44444444-4444-4444-4444-444444444444'
    $env:AZURE_RESOURCE_GROUP = 'offline-rg'
    $env:AZURE_ENV_NAME = 'offline'
    $env:AZURE_LOCATION = 'eastus2'
    $env:MPT_TENANT_ID = $tenant
    $env:MPT_BOOTSTRAP_DEPLOYMENT = 'offline-bootstrap-vnet'
    $scope = "/subscriptions/$env:AZURE_SUBSCRIPTION_ID/resourceGroups/$env:AZURE_RESOURCE_GROUP"
    $stem = 'mpt-abcdefgh'
    $vnetId = "$scope/providers/Microsoft.Network/virtualNetworks/$stem-vnet"
    $outputs = @{
        MPT_NETWORK_MODE = 'storage-private-endpoints-v1'; AZURE_RESOURCE_GROUP = $env:AZURE_RESOURCE_GROUP
        AZURE_CONTAINER_APPS_ENVIRONMENT_ID = "$scope/providers/Microsoft.App/managedEnvironments/$stem-env-vnet"
        MPT_WEB_APP_NAME = "$stem-web-vnet"; MPT_WORKER_JOB_NAME = "$stem-render-vnet"
        MPT_MAINTENANCE_JOB_NAME = "$stem-maintain-vnet"; MPT_STORAGE_ACCOUNT = 'offlinestorage'
        MPT_STORAGE_RESOURCE_ID = "$scope/providers/Microsoft.Storage/storageAccounts/offlinestorage"
        AZURE_VIRTUAL_NETWORK_ID = $vnetId; MPT_ACA_SUBNET_ID = "$vnetId/subnets/aca-infrastructure"
        MPT_PRIVATE_ENDPOINT_SUBNET_ID = "$vnetId/subnets/storage-private-endpoints"
        MPT_STORAGE_PRIVATE_ENDPOINT_IDS = @(); MPT_PRIVATE_DNS_ZONE_IDS = @(); MPT_PRIVATE_DNS_LINK_IDS = @()
    }
    $resources = @{
        $outputs.MPT_STORAGE_RESOURCE_ID = @{ properties = @{
            publicNetworkAccess = 'Disabled'; networkAcls = @{ defaultAction = 'Deny' }
            allowSharedKeyAccess = $false; allowBlobPublicAccess = $false
        } }
        $outputs.AZURE_CONTAINER_APPS_ENVIRONMENT_ID = @{ properties = @{
            provisioningState = 'Succeeded'
            vnetConfiguration = @{ infrastructureSubnetId = $outputs.MPT_ACA_SUBNET_ID; internal = $false }
            workloadProfiles = @(@{ workloadProfileType = 'Consumption' }); defaultDomain = 'new.example.test'
        } }
        $outputs.MPT_ACA_SUBNET_ID = @{ properties = @{
            addressPrefix = '10.247.0.0/23'
            delegations = @(@{ properties = @{ serviceName = 'Microsoft.App/environments' } })
        } }
        $outputs.MPT_PRIVATE_ENDPOINT_SUBNET_ID = @{ properties = @{
            addressPrefix = '10.247.2.0/27'; privateEndpointNetworkPolicies = 'Disabled'
        } }
    }
    foreach ($service in @('blob', 'queue', 'table')) {
        $endpointId = "$scope/providers/Microsoft.Network/privateEndpoints/$stem-pe-$service"
        $zoneId = "$scope/providers/Microsoft.Network/privateDnsZones/privatelink.$service.core.windows.net"
        $linkId = "$zoneId/virtualNetworkLinks/$stem-vnet"
        $outputs.MPT_STORAGE_PRIVATE_ENDPOINT_IDS += $endpointId
        $outputs.MPT_PRIVATE_DNS_ZONE_IDS += $zoneId
        $outputs.MPT_PRIVATE_DNS_LINK_IDS += $linkId
        $resources[$endpointId] = @{ properties = @{
            provisioningState = 'Succeeded'; subnet = @{ id = $outputs.MPT_PRIVATE_ENDPOINT_SUBNET_ID }
            privateLinkServiceConnections = @(@{ properties = @{
                privateLinkServiceId = $outputs.MPT_STORAGE_RESOURCE_ID; groupIds = @($service)
                privateLinkServiceConnectionState = @{ status = 'Approved' }
            } })
        } }
        $resources["$endpointId/privateDnsZoneGroups/default"] = @{ properties = @{
            privateDnsZoneConfigs = @(@{ properties = @{ privateDnsZoneId = $zoneId } })
        } }
        $resources[$linkId] = @{ properties = @{
            provisioningState = 'Succeeded'; registrationEnabled = $false; virtualNetwork = @{ id = $vnetId }
        } }
    }
    $testState.NetworkResources = $resources
    $status = Get-PrivateNetworkStatus $outputs
    Assert-Test ($status.Callback -eq "https://$stem-web-vnet.new.example.test/.auth/login/aad/callback") 'Callback must use the new environment, not the legacy/internal hostname.'
    $fallback = $outputs.Clone()
    foreach ($key in @('AZURE_LOCATION', 'AZURE_CONTAINER_REGISTRY_NAME', 'AZURE_CONTAINER_REGISTRY_ENDPOINT',
        'MPT_WEB_IDENTITY_ID', 'MPT_WEB_CLIENT_ID', 'MPT_WORKER_IDENTITY_ID', 'MPT_WORKER_CLIENT_ID')) {
        $fallback[$key] = 'offline-value'
    }
    $savedOutputsEnvironment = @{ MPT_BOOTSTRAP_DEPLOYMENT = $env:MPT_BOOTSTRAP_DEPLOYMENT }
    try {
        $env:MPT_BOOTSTRAP_DEPLOYMENT = ''
        foreach ($key in $fallback.Keys) {
            $savedOutputsEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
            $value = $fallback[$key]
            if ($value -is [array]) { $value = ConvertTo-Json -InputObject $value -Compress }
            [Environment]::SetEnvironmentVariable($key, [string]$value)
        }
        $loaded = Get-BootstrapOutputs
        Assert-PrivateRuntimeOutputs $loaded
        Assert-Test ($loaded.MPT_STORAGE_PRIVATE_ENDPOINT_IDS.Count -eq 3) 'azd JSON-array endpoint outputs must be decoded.'
        Assert-Test ($loaded.MPT_PRIVATE_DNS_LINK_IDS[2] -eq $outputs.MPT_PRIVATE_DNS_LINK_IDS[2]) 'azd array output order must be retained.'
    }
    finally {
        foreach ($key in $savedOutputsEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $savedOutputsEnvironment[$key]) }
    }
    foreach ($key in @('MPT_NETWORK_MODE', 'AZURE_RESOURCE_GROUP', 'AZURE_CONTAINER_APPS_ENVIRONMENT_ID', 'MPT_WEB_APP_NAME',
        'MPT_WORKER_JOB_NAME', 'MPT_MAINTENANCE_JOB_NAME', 'MPT_ACA_SUBNET_ID', 'MPT_PRIVATE_ENDPOINT_SUBNET_ID')) {
        $bad = $outputs.Clone()
        $bad[$key] = 'legacy-value'
        $denied = $false
        try { Assert-PrivateRuntimeOutputs $bad } catch { $denied = $true }
        Assert-Test $denied "Legacy output must be rejected: $key."
    }
    foreach ($case in @(
        @{ Name = 'Public Storage'; Change = { $testState.NetworkResources[$outputs.MPT_STORAGE_RESOURCE_ID].properties.publicNetworkAccess = 'Enabled' } },
        @{ Name = 'Unbound environment'; Change = { $testState.NetworkResources[$outputs.AZURE_CONTAINER_APPS_ENVIRONMENT_ID].properties.vnetConfiguration.infrastructureSubnetId = '/wrong' } },
        @{ Name = 'Unapproved PE'; Change = { $testState.NetworkResources[$outputs.MPT_STORAGE_PRIVATE_ENDPOINT_IDS[0]].properties.privateLinkServiceConnections[0].properties.privateLinkServiceConnectionState.status = 'Pending' } },
        @{ Name = 'Wrong queue PE target'; Change = { $testState.NetworkResources[$outputs.MPT_STORAGE_PRIVATE_ENDPOINT_IDS[1]].properties.privateLinkServiceConnections[0].properties.privateLinkServiceId = '/wrong' } },
        @{ Name = 'Wrong table PE subnet'; Change = { $testState.NetworkResources[$outputs.MPT_STORAGE_PRIVATE_ENDPOINT_IDS[2]].properties.subnet.id = '/wrong' } },
        @{ Name = 'Wrong DNS VNet'; Change = { $testState.NetworkResources[$outputs.MPT_PRIVATE_DNS_LINK_IDS[0]].properties.virtualNetwork.id = '/wrong' } },
        @{ Name = 'Wrong DNS zone group'; Change = { $testState.NetworkResources["$($outputs.MPT_STORAGE_PRIVATE_ENDPOINT_IDS[1])/privateDnsZoneGroups/default"].properties.privateDnsZoneConfigs[0].properties.privateDnsZoneId = '/wrong' } }
    )) {
        $testState.NetworkResources = $resources | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        & $case.Change
        $denied = $false
        try { $null = Get-PrivateNetworkStatus $outputs } catch { $denied = $true }
        Assert-Test $denied "Unsafe live network was accepted: $($case.Name)."
    }
    $testState.BootstrapOutputs = $outputs.Clone()
    $testState.BootstrapOutputs.Remove('MPT_NETWORK_MODE')
    foreach ($scriptName in @('Deploy-Azure.ps1', 'Publish-Azure.ps1')) {
        $arguments = @{}
        if ($scriptName -eq 'Deploy-Azure.ps1') {
            $arguments = @{ Phase = 'Runtime'; EntraClientSecret = ConvertTo-SecureString 'offline-only' -AsPlainText -Force }
        }
        $failureMessage = ''
        try { & (Join-Path $PSScriptRoot $scriptName) @arguments } catch { $failureMessage = $_.Exception.Message }
        Assert-Test ($failureMessage -like 'Stale bootstrap outputs:*') "$scriptName must reject legacy outputs before any ingress/job mutation."
    }
}
finally {
    foreach ($key in $networkEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $networkEnvironment[$key]) }
}

Write-Host "$($testState.Checks) offline infrastructure-tooling checks passed; no Azure resources or image builds were invoked."
