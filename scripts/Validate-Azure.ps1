#requires -Version 7.2
[CmdletBinding()]
param()
. "$PSScriptRoot\Azure-Common.ps1"

function Assert-Contract {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-PrivateNetworkTemplate {
    param([hashtable]$Template)
    $foundation = @($Template.resources | Where-Object {
        $_.type -eq 'Microsoft.Resources/deployments' -and
        'Microsoft.App/managedEnvironments' -in $_.properties.template.resources.type
    })[0].properties.template
    $networkModule = @($foundation.resources | Where-Object {
        $_.type -eq 'Microsoft.Resources/deployments' -and
        'Microsoft.Network/virtualNetworks' -in $_.properties.template.resources.type
    })[0]
    $network = $networkModule.properties.template
    $storageModule = @($foundation.resources | Where-Object {
        $_.type -eq 'Microsoft.Resources/deployments' -and
        'Microsoft.Storage/storageAccounts' -in $_.properties.template.resources.type
    })[0]
    $storage = @($storageModule.properties.template.resources |
        Where-Object type -EQ 'Microsoft.Storage/storageAccounts')[0].properties
    Assert-Contract ($storage.publicNetworkAccess -eq 'Disabled' -and
        $storage.networkAcls.defaultAction -eq 'Deny') 'Storage public networking must remain Disabled/Deny.'
    Assert-Contract ($storage.networkAcls.bypass -eq 'None' -and
        $storage.allowBlobPublicAccess -eq $false -and $storage.allowSharedKeyAccess -eq $false -and
        $storage.defaultToOAuthAuthentication -eq $true) 'Storage must remain private and keyless without bypass.'
    Assert-Contract ($storage.minimumTlsVersion -eq 'TLS1_2' -and
        $storage.supportsHttpsTrafficOnly -eq $true) 'Storage must require HTTPS and TLS 1.2.'
    $containers = @($storageModule.properties.template.resources |
        Where-Object type -EQ 'Microsoft.Storage/storageAccounts/blobServices/containers')
    Assert-Contract ($containers.Count -eq 1 -and $containers[0].properties.publicAccess -eq 'None') 'Tasks blobs must remain private.'
    Assert-Contract ($storageModule.properties.template.outputs.resourceId.value -eq
        "[resourceId('Microsoft.Storage/storageAccounts', parameters('name'))]") 'Storage resource output must reference the actual account.'
    Assert-Contract ($networkModule.properties.parameters.storageAccountResourceId.value -eq
        "[reference(resourceId('Microsoft.Resources/deployments', 'storage'), '$($storageModule.apiVersion)').outputs.resourceId.value]") 'PEs must target the provisioned Storage module output.'
    Assert-Contract (($network.variables.services -join ',') -eq 'blob,queue,table') 'Exactly blob/queue/table private endpoints are required.'
    Assert-Contract ($network.resources.Count -eq 5) 'Network module must only create VNet, PE, DNS zones, links and groups.'
    $vnet = @($network.resources | Where-Object type -EQ 'Microsoft.Network/virtualNetworks')[0]
    $subnets = $vnet.properties.subnets
    Assert-Contract (($vnet.properties.addressSpace.addressPrefixes -join ',') -eq '10.247.0.0/16' -and
        $subnets.Count -eq 2) 'Unexpected VNet range or subnet count.'
    $acaSubnet = @($subnets | Where-Object name -EQ 'aca-infrastructure')[0].properties
    $peSubnet = @($subnets | Where-Object name -EQ 'storage-private-endpoints')[0].properties
    Assert-Contract ($acaSubnet.addressPrefix -eq '10.247.0.0/23' -and
        ($acaSubnet.delegations.properties.serviceName -join ',') -eq 'Microsoft.App/environments') 'ACA requires its exclusive delegated infrastructure subnet.'
    Assert-Contract ($peSubnet.addressPrefix -eq '10.247.2.0/27' -and
        $peSubnet.privateEndpointNetworkPolicies -eq 'Disabled' -and
        -not $peSubnet.ContainsKey('delegations')) 'PE subnet must be separate and nondelegated.'
    $vnetId = "[resourceId('Microsoft.Network/virtualNetworks', format('{0}-vnet', parameters('name')))]"
    $zoneId = "[resourceId('Microsoft.Network/privateDnsZones', format('privatelink.{0}.{1}', variables('services')[copyIndex()], environment().suffixes.storage))]"
    $endpointId = "[resourceId('Microsoft.Network/privateEndpoints', format('{0}-pe-{1}', parameters('name'), variables('services')[copyIndex()]))]"
    $acaSubnetId = "[format('{0}/subnets/aca-infrastructure', resourceId('Microsoft.Network/virtualNetworks', format('{0}-vnet', parameters('name'))))]"
    $peSubnetId = "[format('{0}/subnets/storage-private-endpoints', resourceId('Microsoft.Network/virtualNetworks', format('{0}-vnet', parameters('name'))))]"
    $endpoint = @($network.resources | Where-Object type -EQ 'Microsoft.Network/privateEndpoints')[0]
    $zone = @($network.resources | Where-Object type -EQ 'Microsoft.Network/privateDnsZones')[0]
    $link = @($network.resources | Where-Object type -EQ 'Microsoft.Network/privateDnsZones/virtualNetworkLinks')[0]
    $group = @($network.resources | Where-Object type -EQ 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups')[0]
    foreach ($resource in @($endpoint, $zone, $link, $group)) {
        Assert-Contract ($resource.copy.count -eq "[length(variables('services'))]") 'Each service needs a PE, zone, link and zone group.'
    }
    Assert-Contract ($endpoint.properties.subnet.id -eq $peSubnetId -and
        $endpoint.properties.privateLinkServiceConnections.Count -eq 1) 'Every PE must bind the PE subnet with one Storage connection.'
    $connection = $endpoint.properties.privateLinkServiceConnections[0].properties
    Assert-Contract ($connection.privateLinkServiceId -eq "[parameters('storageAccountResourceId')]" -and
        $connection.groupIds.Count -eq 1 -and
        $connection.groupIds[0] -eq "[variables('services')[copyIndex()]]") 'PE target/group must reference the actual account and corresponding service.'
    Assert-Contract ($zone.name -eq "[format('privatelink.{0}.{1}', variables('services')[copyIndex()], environment().suffixes.storage)]" -and
        $zone.location -eq 'global') 'Storage Private DNS zone names are incorrect.'
    Assert-Contract ($link.name -eq "[format('{0}/{1}', format('privatelink.{0}.{1}', variables('services')[copyIndex()], environment().suffixes.storage), format('{0}-vnet', parameters('name')))]" -and
        $link.properties.virtualNetwork.id -eq $vnetId -and
        $link.properties.registrationEnabled -eq $false) 'Each DNS zone must link to the actual application VNet without auto-registration.'
    Assert-Contract ($group.name -eq "[format('{0}/{1}', format('{0}-pe-{1}', parameters('name'), variables('services')[copyIndex()]), 'default')]" -and
        $group.properties.privateDnsZoneConfigs.Count -eq 1 -and
        $group.properties.privateDnsZoneConfigs[0].properties.privateDnsZoneId -eq $zoneId -and
        $endpointId -in $group.dependsOn -and $zoneId -in $group.dependsOn) 'DNS groups must bind corresponding PEs and zones, not merely exist.'
    Assert-Contract ($network.outputs.vnetId.value -eq $vnetId -and
        $network.outputs.infrastructureSubnetId.value -eq $acaSubnetId -and
        $network.outputs.privateEndpointSubnetId.value -eq $peSubnetId -and
        $network.outputs.privateEndpointIds.copy.input -eq $endpointId -and
        $network.outputs.privateDnsZoneIds.copy.input -eq $zoneId) 'Network outputs must reference deployed resources.'
    $environment = @($foundation.resources | Where-Object type -EQ 'Microsoft.App/managedEnvironments')[0]
    Assert-Contract ($environment.name -eq "[format('{0}-env-vnet', variables('stem'))]" -and
        $environment.properties.vnetConfiguration.infrastructureSubnetId -eq
        "[reference(resourceId('Microsoft.Resources/deployments', 'private-network'), '$($networkModule.apiVersion)').outputs.infrastructureSubnetId.value]" -and
        $environment.properties.vnetConfiguration.internal -eq $false) 'Create a new external-capable environment bound to the actual ACA subnet.'
    Assert-Contract ($environment.properties.workloadProfiles.Count -eq 1 -and
        $environment.properties.workloadProfiles[0].workloadProfileType -eq 'Consumption') 'No dedicated workload profile is allowed.'
    foreach ($pair in @{ webAppName = 'web'; workerJobName = 'render'; maintenanceJobName = 'maintain' }.GetEnumerator()) {
        Assert-Contract ($foundation.outputs[$pair.Key].value -eq "[format('{0}-$($pair.Value)-vnet', variables('stem'))]") 'Runtime outputs must use new -vnet names, never legacy resources.'
    }
    Assert-Contract ($Template.outputs.MPT_NETWORK_MODE.value -eq 'storage-private-endpoints-v1') 'Private-network output marker is missing.'
    foreach ($deployment in @($Template.resources) + @($foundation.resources) |
        Where-Object type -EQ 'Microsoft.Resources/deployments') {
        Assert-Contract ($deployment.properties.mode -eq 'Incremental') 'Complete deployments could delete the legacy runtime or data.'
    }
}

$scriptFiles = Get-ChildItem $PSScriptRoot -Filter '*Azure*.ps1'
foreach ($file in $scriptFiles) {
    $parseErrors = $null
    $tokens = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    Assert-Contract ($parseErrors.Count -eq 0) "PowerShell syntax errors in $($file.Name): $parseErrors"
}
$main = (Invoke-Az @('bicep', 'build', '--file',
    (Join-Path $script:RepositoryRoot 'infra\main.bicep'), '--stdout')) | ConvertFrom-Json -AsHashtable
$runtime = (Invoke-Az @('bicep', 'build', '--file',
    (Join-Path $script:RepositoryRoot 'infra\runtime.bicep'), '--stdout')) | ConvertFrom-Json -AsHashtable
Assert-Contract ($main.resources.Count -gt 0) 'Bootstrap template has no resources.'
Assert-Contract ($runtime.parameters.entraClientSecret.type -eq 'secureString') 'Entra secret is not a secure parameter.'
Assert-Contract ($runtime.parameters.internalApiToken.type -eq 'secureString') 'Internal token is not a secure parameter.'
Assert-Contract ($runtime.parameters.speechResourceId.minLength -eq 1) 'The Speech resource ID must not be empty.'
Assert-Contract (-not $runtime.parameters.speechResourceId.ContainsKey('defaultValue')) 'The Speech resource ID must be explicitly provided.'

Assert-PrivateNetworkTemplate $main

$nested = @($runtime.resources | ForEach-Object { $_.properties.template.resources })
$web = @($nested | Where-Object type -EQ 'Microsoft.App/containerApps')[0]
$auth = @($nested | Where-Object type -EQ 'Microsoft.App/containerApps/authConfigs')[0]
Assert-Contract ($web.properties.configuration.ingress.external -eq $false) 'Runtime must start with internal ingress.'
Assert-Contract ($web.properties.configuration.ingress.targetPort -eq 8501) 'Only Streamlit may be exposed.'
Assert-Contract ($web.properties.configuration.ingress.allowInsecure -eq $false) 'HTTPS-only ingress is required.'
Assert-Contract ($web.properties.template.scale.maxReplicas -eq 1) 'Web replica cap changed.'
Assert-Contract ($web.properties.template.containers.Count -eq 2) 'UI/API sidecar contract changed.'
$api = @($web.properties.template.containers | Where-Object name -EQ 'api')[0]
Assert-Contract ('127.0.0.1' -in $api.args -and '8080' -in $api.args) 'API must bind loopback:8080.'
Assert-Contract ($auth.properties.platform.enabled -eq $true) 'Platform authentication is disabled.'
Assert-Contract ($auth.properties.globalValidation.excludedPaths.Count -eq 0) 'No anonymous paths may be excluded.'
Assert-Contract ($auth.properties.globalValidation.unauthenticatedClientAction -eq 'RedirectToLoginPage') 'Anonymous authentication policy changed.'
Assert-Contract ($null -ne $auth.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals.identities) 'Platform OID allowlist is missing.'

$docker = Get-Content (Join-Path $script:RepositoryRoot 'Dockerfile.azure') -Raw
Assert-Contract ($docker.Contains('python:3.11-slim-bookworm')) 'Unexpected container Python base.'
Assert-Contract ($docker.Contains('uv sync --frozen --no-dev')) 'Container dependencies must use the lockfile.'
Assert-Contract ($docker.Contains('USER 10001:10001')) 'Container must run as nonroot.'
Assert-Contract (-not ($docker -match '(?m)^COPY\s+\.\s')) 'Do not copy the entire repository into the image.'
$null = Get-Content (Join-Path $script:RepositoryRoot 'infra\main.parameters.json') -Raw | ConvertFrom-Json
Write-Host 'Static validation passed: compiled PE targets/subnets/DNS links, Storage Disabled/keyless, blue-green Consumption environment, secure/internal auth, PowerShell, Docker and parameters.'
Write-Host 'This script does not verify effective live network/policy settings, ARM provider validation/what-if, remote image build, Graph registration, live RBAC, or authenticated end-to-end behavior.'
