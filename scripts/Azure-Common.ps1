#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:RepositoryRoot = Split-Path $PSScriptRoot -Parent

function Get-RequiredEnvironment {
    param([Parameter(Mandatory)][string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Set $Name before continuing." }
    return $value.Trim()
}

function Invoke-Az {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Arguments)
    $result = & az @Arguments --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI operation failed (exit $LASTEXITCODE)." }
    return $result
}

function Assert-AzureContext {
    $subscription = Get-RequiredEnvironment AZURE_SUBSCRIPTION_ID
    $tenant = Get-RequiredEnvironment MPT_TENANT_ID
    $account = (Invoke-Az @('account', 'show', '--output', 'json')) | ConvertFrom-Json
    if ($account.id -ne $subscription -or $account.tenantId -ne $tenant) {
        throw 'Active Azure CLI subscription/tenant differs from the requested context. Select it explicitly with az login / az account set.'
    }
}

function Get-BootstrapOutputs {
    if ($env:MPT_BOOTSTRAP_DEPLOYMENT) {
        $deployment = $env:MPT_BOOTSTRAP_DEPLOYMENT
        $outputs = (Invoke-Az @('deployment', 'sub', 'show', '--name', $deployment,
            '--query', 'properties.outputs', '--output', 'json')) | ConvertFrom-Json -AsHashtable
        $values = @{}
        foreach ($key in $outputs.Keys) { $values[$key] = $outputs[$key].value }
        return $values
    }
    # azd exports these outputs as environment variables. No secret values belong here.
    $values = @{}
    foreach ($key in @('AZURE_RESOURCE_GROUP', 'AZURE_LOCATION', 'AZURE_CONTAINER_REGISTRY_NAME',
            'AZURE_CONTAINER_REGISTRY_ENDPOINT', 'AZURE_CONTAINER_APPS_ENVIRONMENT_ID',
            'MPT_STORAGE_ACCOUNT', 'MPT_WEB_IDENTITY_ID', 'MPT_WEB_CLIENT_ID',
            'MPT_WORKER_IDENTITY_ID', 'MPT_WORKER_CLIENT_ID', 'MPT_WEB_APP_NAME',
            'MPT_WORKER_JOB_NAME', 'MPT_MAINTENANCE_JOB_NAME', 'MPT_NETWORK_MODE',
            'MPT_STORAGE_RESOURCE_ID', 'AZURE_VIRTUAL_NETWORK_ID', 'MPT_ACA_SUBNET_ID',
            'MPT_PRIVATE_ENDPOINT_SUBNET_ID')) {
        $values[$key] = Get-RequiredEnvironment $key
    }
    foreach ($key in @('MPT_STORAGE_PRIVATE_ENDPOINT_IDS', 'MPT_PRIVATE_DNS_ZONE_IDS', 'MPT_PRIVATE_DNS_LINK_IDS')) {
        $values[$key] = @(Get-RequiredEnvironment $key | ConvertFrom-Json)
    }
    return $values
}

function Invoke-Arm {
    param(
        [Parameter(Mandatory)][string]$ResourcePath,
        [string]$Method = 'GET',
        [object]$Body,
        [switch]$AllowNotFound
    )
    if ($AllowNotFound -and $Method -ne 'GET') { throw '-AllowNotFound is only valid for an existence-check GET.' }
    # Secure deployment values stay in this process, never CLI arguments or a parameter file.
    $token = Invoke-Az @('account', 'get-access-token', '--resource',
        'https://management.azure.com/', '--query', 'accessToken', '--output', 'tsv')
    $request = @{
        Uri = "https://management.azure.com$ResourcePath"
        Method = $Method
        Headers = @{ Authorization = "Bearer $token" }
        ContentType = 'application/json'
    }
    if ($null -ne $Body) { $request.Body = ConvertTo-Json $Body -Depth 100 -Compress }
    try { return Invoke-RestMethod @request }
    catch {
        $failure = $_
        $httpStatus = 'unavailable'
        $errorCode = 'NoHttpResponse'
        $responseProperty = $failure.Exception.PSObject.Properties['Response']
        if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
            $httpStatus = [string][int]$responseProperty.Value.StatusCode
            $errorCode = 'UnspecifiedServiceError'
        }
        if ($AllowNotFound -and $httpStatus -eq '404') {
            Write-Verbose 'The requested resource does not exist yet.'
            return $null
        }
        if ($null -ne $failure.ErrorDetails -and
            -not [string]::IsNullOrWhiteSpace($failure.ErrorDetails.Message)) {
            $serviceError = $null
            try {
                $serviceError = ConvertFrom-Json -InputObject $failure.ErrorDetails.Message `
                    -AsHashtable -ErrorAction Stop
            }
            catch [System.ArgumentException] {
                $errorCode = 'UnparseableErrorResponse'
            }
            if ($serviceError -is [System.Collections.IDictionary] -and
                $serviceError['error'] -is [System.Collections.IDictionary]) {
                $candidate = $serviceError['error']['code']
                # Never print service messages or arbitrary response text.
                if ($candidate -is [string] -and $candidate -cmatch '^[A-Za-z][A-Za-z0-9_.-]{0,79}$') {
                    $errorCode = $candidate
                }
            }
        }
        throw "ARM request failed (HTTP $httpStatus; code $errorCode). Inspect the Azure activity/deployment log; request bodies and service messages are not logged. Check whether the operation was accepted before retrying."
    }
    finally {
        $token = $null
        $request = $null
    }
}

function Get-ObjectIdAllowlist {
    $ids = @((Get-RequiredEnvironment MPT_ALLOWED_OIDS).Split(',') |
        ForEach-Object { $_.Trim().ToLowerInvariant() } | Sort-Object -Unique)
    foreach ($id in $ids) {
        $parsed = [guid]::Empty
        if (-not [guid]::TryParse($id, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
            throw 'MPT_ALLOWED_OIDS must be a nonempty comma-separated list of Entra object IDs.'
        }
    }
    return ,$ids
}

function Assert-PrivateRuntimeOutputs {
    param([Parameter(Mandatory)][hashtable]$Outputs)
    if ($Outputs['MPT_NETWORK_MODE'] -ne 'storage-private-endpoints-v1') {
        throw 'Stale bootstrap outputs: provision the private network first. Legacy apps/jobs will not be changed.'
    }
    $scope = "/subscriptions/$(Get-RequiredEnvironment AZURE_SUBSCRIPTION_ID)/resourceGroups/$(Get-RequiredEnvironment AZURE_RESOURCE_GROUP)"
    if ($Outputs['AZURE_RESOURCE_GROUP'] -ne (Get-RequiredEnvironment AZURE_RESOURCE_GROUP)) {
        throw 'Bootstrap resource group differs from the requested resource group.'
    }
    $environmentId = [string]$Outputs['AZURE_CONTAINER_APPS_ENVIRONMENT_ID']
    $prefix = "$scope/providers/Microsoft.App/managedEnvironments/"
    if (-not $environmentId.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        $environmentId.Split('/')[-1] -notmatch '^mpt-[a-z0-9]{8}-env-vnet$') {
        throw 'Refusing to target a legacy or out-of-scope Container Apps environment.'
    }
    $stem = $environmentId.Split('/')[-1] -replace '-env-vnet$', ''
    foreach ($pair in @{
        MPT_WEB_APP_NAME = "$stem-web-vnet"
        MPT_WORKER_JOB_NAME = "$stem-render-vnet"
        MPT_MAINTENANCE_JOB_NAME = "$stem-maintain-vnet"
        AZURE_VIRTUAL_NETWORK_ID = "$scope/providers/Microsoft.Network/virtualNetworks/$stem-vnet"
        MPT_STORAGE_RESOURCE_ID = "$scope/providers/Microsoft.Storage/storageAccounts/$($Outputs['MPT_STORAGE_ACCOUNT'])"
    }.GetEnumerator()) {
        if ($Outputs[$pair.Key] -ne $pair.Value) { throw "Unexpected private-network output: $($pair.Key)." }
    }
    if ($Outputs['MPT_ACA_SUBNET_ID'] -ne "$($Outputs.AZURE_VIRTUAL_NETWORK_ID)/subnets/aca-infrastructure" -or
        $Outputs['MPT_PRIVATE_ENDPOINT_SUBNET_ID'] -ne "$($Outputs.AZURE_VIRTUAL_NETWORK_ID)/subnets/storage-private-endpoints") {
        throw 'Private-network subnet outputs are inconsistent.'
    }
    foreach ($key in @('MPT_STORAGE_PRIVATE_ENDPOINT_IDS', 'MPT_PRIVATE_DNS_ZONE_IDS', 'MPT_PRIVATE_DNS_LINK_IDS')) {
        if ($Outputs[$key] -is [string] -or @($Outputs[$key]).Count -ne 3) {
            throw "Expected three ordered blob/queue/table resources in $key."
        }
    }
    $services = @('blob', 'queue', 'table')
    for ($i = 0; $i -lt $services.Count; $i++) {
        $zoneId = "$scope/providers/Microsoft.Network/privateDnsZones/privatelink.$($services[$i]).core.windows.net"
        if ($Outputs.MPT_STORAGE_PRIVATE_ENDPOINT_IDS[$i] -ne "$scope/providers/Microsoft.Network/privateEndpoints/$stem-pe-$($services[$i])" -or
            $Outputs.MPT_PRIVATE_DNS_ZONE_IDS[$i] -ne $zoneId -or
            $Outputs.MPT_PRIVATE_DNS_LINK_IDS[$i] -ne "$zoneId/virtualNetworkLinks/$stem-vnet") {
            throw "Unexpected resource scope or ordering for the $($services[$i]) private endpoint/DNS."
        }
    }
}

function Get-PrivateNetworkStatus {
    param([Parameter(Mandatory)][hashtable]$Outputs)
    Assert-PrivateRuntimeOutputs $Outputs
    $storage = (Invoke-Arm "$($Outputs.MPT_STORAGE_RESOURCE_ID)?api-version=2023-05-01").properties
    if ($storage.publicNetworkAccess -ne 'Disabled' -or $storage.networkAcls.defaultAction -ne 'Deny' -or
        $storage.allowSharedKeyAccess -ne $false -or $storage.allowBlobPublicAccess -ne $false) {
        throw 'Live Storage must deny public network access, anonymous blobs, and Shared Key authentication.'
    }
    $environment = (Invoke-Arm "$($Outputs.AZURE_CONTAINER_APPS_ENVIRONMENT_ID)?api-version=2025-01-01").properties
    if ($environment.provisioningState -ne 'Succeeded' -or [string]::IsNullOrWhiteSpace($environment.defaultDomain) -or
        $environment.vnetConfiguration.infrastructureSubnetId -ne $Outputs.MPT_ACA_SUBNET_ID -or
        $environment.vnetConfiguration.internal -ne $false -or
        @($environment.workloadProfiles).Count -ne 1 -or
        $environment.workloadProfiles[0].workloadProfileType -ne 'Consumption') {
        throw 'New ACA environment does not match the VNet-injected Consumption profile.'
    }
    $subnet = (Invoke-Arm "$($Outputs.MPT_ACA_SUBNET_ID)?api-version=2024-05-01").properties
    if ($subnet.addressPrefix -ne '10.247.0.0/23' -or
        'Microsoft.App/environments' -notin @($subnet.delegations.properties.serviceName)) {
        throw 'ACA infrastructure subnet address/delegation is incorrect.'
    }
    $peSubnet = (Invoke-Arm "$($Outputs.MPT_PRIVATE_ENDPOINT_SUBNET_ID)?api-version=2024-05-01").properties
    if ($peSubnet.addressPrefix -ne '10.247.2.0/27' -or $peSubnet.privateEndpointNetworkPolicies -ne 'Disabled') {
        throw 'Private endpoints must use the separate 10.247.2.0/27 subnet.'
    }
    $services = @('blob', 'queue', 'table')
    for ($i = 0; $i -lt $services.Count; $i++) {
        $endpointId = $Outputs.MPT_STORAGE_PRIVATE_ENDPOINT_IDS[$i]
        $endpoint = (Invoke-Arm "${endpointId}?api-version=2024-05-01").properties
        $connections = @($endpoint.privateLinkServiceConnections)
        if ($endpoint.provisioningState -ne 'Succeeded' -or
            $endpoint.subnet.id -ne $Outputs.MPT_PRIVATE_ENDPOINT_SUBNET_ID -or $connections.Count -ne 1 -or
            $connections[0].properties.privateLinkServiceId -ne $Outputs.MPT_STORAGE_RESOURCE_ID -or
            $connections[0].properties.privateLinkServiceConnectionState.status -ne 'Approved' -or
            @($connections[0].properties.groupIds).Count -ne 1 -or
            $connections[0].properties.groupIds[0] -ne $services[$i]) {
            throw "The $($services[$i]) private endpoint is not approved/bound to the intended Storage and subnet."
        }
        $zoneGroup = (Invoke-Arm "$endpointId/privateDnsZoneGroups/default?api-version=2024-05-01").properties
        if (@($zoneGroup.privateDnsZoneConfigs).Count -ne 1 -or
            $zoneGroup.privateDnsZoneConfigs[0].properties.privateDnsZoneId -ne $Outputs.MPT_PRIVATE_DNS_ZONE_IDS[$i]) {
            throw "The $($services[$i]) private endpoint has an incorrect DNS zone group."
        }
        $link = (Invoke-Arm "$($Outputs.MPT_PRIVATE_DNS_LINK_IDS[$i])?api-version=2020-06-01").properties
        if ($link.provisioningState -ne 'Succeeded' -or $link.registrationEnabled -ne $false -or
            $link.virtualNetwork.id -ne $Outputs.AZURE_VIRTUAL_NETWORK_ID) {
            throw "The $($services[$i]) private DNS zone is not linked to the application VNet."
        }
    }
    $hostName = "$($Outputs.MPT_WEB_APP_NAME).$($environment.defaultDomain)"
    return [pscustomobject]@{ PublicUrl = "https://$hostName"; Callback = "https://$hostName/.auth/login/aad/callback" }
}
