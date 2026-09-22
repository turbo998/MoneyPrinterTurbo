#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Bootstrap', 'Runtime')][string]$Phase,
    [SecureString]$EntraClientSecret
)
. "$PSScriptRoot\Azure-Common.ps1"
Assert-AzureContext
$environmentName = Get-RequiredEnvironment AZURE_ENV_NAME
$location = Get-RequiredEnvironment AZURE_LOCATION

if ($Phase -eq 'Bootstrap') {
    & "$PSScriptRoot\Validate-Azure.ps1"
    $deployment = "$environmentName-bootstrap-vnet"
    $arguments = @('deployment', 'sub', 'create', '--name', $deployment, '--location', $location,
        '--template-file', (Join-Path $script:RepositoryRoot 'infra\main.bicep'), '--parameters',
        "environmentName=$environmentName", "location=$location",
        "resourceGroupName=$(Get-RequiredEnvironment AZURE_RESOURCE_GROUP)",
        "textResourceGroup=$(Get-RequiredEnvironment MPT_TEXT_RESOURCE_GROUP)",
        "textAccountName=$(Get-RequiredEnvironment MPT_TEXT_ACCOUNT_NAME)",
        "imageResourceGroup=$(Get-RequiredEnvironment MPT_IMAGE_RESOURCE_GROUP)",
        "imageAccountName=$(Get-RequiredEnvironment MPT_IMAGE_ACCOUNT_NAME)",
        "speechResourceGroup=$(Get-RequiredEnvironment MPT_SPEECH_RESOURCE_GROUP)",
        "speechAccountName=$(Get-RequiredEnvironment MPT_SPEECH_ACCOUNT_NAME)", '--output', 'none')
    Invoke-Az $arguments
    $env:MPT_BOOTSTRAP_DEPLOYMENT = $deployment
    Write-Host "Private foundation deployed; legacy environment/apps/jobs were not targeted. Set MPT_BOOTSTRAP_DEPLOYMENT=$deployment in subsequent shells."
    return
}

if (-not $EntraClientSecret -or $EntraClientSecret.Length -eq 0) {
    throw 'Runtime requires -EntraClientSecret (Read-Host -AsSecureString). No anonymous fallback is supported.'
}
$outputs = Get-BootstrapOutputs
$null = Get-PrivateNetworkStatus $outputs
$image = Get-RequiredEnvironment MPT_CONTAINER_IMAGE
if ($image -notmatch "^$([regex]::Escape($outputs.AZURE_CONTAINER_REGISTRY_ENDPOINT))/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$") {
    throw 'MPT_CONTAINER_IMAGE must be an immutable digest from the provisioned ACR.'
}
$allowedObjectIds = Get-ObjectIdAllowlist
$subscription = Get-RequiredEnvironment AZURE_SUBSCRIPTION_ID
$resourceGroup = $outputs.AZURE_RESOURCE_GROUP
$appPath = "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.App/containerApps/$($outputs.MPT_WEB_APP_NAME)"
$existingApp = Invoke-Arm "${appPath}?api-version=2025-01-01" -AllowNotFound
$internalToken = $null
if ($existingApp) {
    # Close ingress before any identity, secret, or authorization changes.
    Invoke-Az @('containerapp', 'ingress', 'enable', '--name', $outputs.MPT_WEB_APP_NAME,
        '--resource-group', $resourceGroup, '--type', 'internal', '--target-port', '8501',
        '--allow-insecure', 'false', '--output', 'none')
    $existingSecrets = Invoke-Arm "$appPath/listSecrets?api-version=2025-01-01" -Method POST
    $savedToken = @($existingSecrets.value | Where-Object name -EQ 'internal-api-token')
    if ($savedToken.Count -eq 1) { $internalToken = $savedToken[0].value }
}
if (-not $internalToken) {
    $internalToken = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(64))
}
if ([Text.Encoding]::UTF8.GetByteCount($internalToken) -lt 43) { throw 'Stored API token is too short.' }
$parameters = @{
    location = $location
    environmentName = $environmentName
    environmentId = $outputs.AZURE_CONTAINER_APPS_ENVIRONMENT_ID
    registryServer = $outputs.AZURE_CONTAINER_REGISTRY_ENDPOINT
    containerImage = $image
    revisionSuffix = 'r' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    storageAccount = $outputs.MPT_STORAGE_ACCOUNT
    webAppName = $outputs.MPT_WEB_APP_NAME
    workerJobName = $outputs.MPT_WORKER_JOB_NAME
    maintenanceJobName = $outputs.MPT_MAINTENANCE_JOB_NAME
    webIdentityId = $outputs.MPT_WEB_IDENTITY_ID
    webClientId = $outputs.MPT_WEB_CLIENT_ID
    workerIdentityId = $outputs.MPT_WORKER_IDENTITY_ID
    workerClientId = $outputs.MPT_WORKER_CLIENT_ID
    tenantId = Get-RequiredEnvironment MPT_TENANT_ID
    entraClientId = Get-RequiredEnvironment MPT_ENTRA_CLIENT_ID
    allowedObjectIds = $allowedObjectIds
    entraClientSecret = [Net.NetworkCredential]::new('', $EntraClientSecret).Password
    internalApiToken = $internalToken
    textEndpoint = Get-RequiredEnvironment MPT_TEXT_ENDPOINT
    textDeployment = Get-RequiredEnvironment MPT_TEXT_DEPLOYMENT
    imageEndpoint = Get-RequiredEnvironment MPT_IMAGE_ENDPOINT
    imageDeployment = Get-RequiredEnvironment MPT_IMAGE_DEPLOYMENT
    speechEndpoint = Get-RequiredEnvironment MPT_SPEECH_ENDPOINT
    speechResourceId = Get-RequiredEnvironment MPT_SPEECH_RESOURCE_ID
    speechRegion = Get-RequiredEnvironment MPT_SPEECH_REGION
}
$armParameters = @{}
foreach ($key in $parameters.Keys) { $armParameters[$key] = @{ value = $parameters[$key] } }
$template = (Invoke-Az @('bicep', 'build', '--file',
    (Join-Path $script:RepositoryRoot 'infra\runtime.bicep'), '--stdout')) | ConvertFrom-Json -AsHashtable
$deploymentPath = "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.Resources/deployments/$environmentName-runtime-vnet?api-version=2022-09-01"
try {
    $null = Invoke-Arm $deploymentPath -Method PUT -Body @{
        properties = @{ mode = 'Incremental'; template = $template; parameters = $armParameters }
    }
    $deadline = [DateTime]::UtcNow.AddMinutes(40)
    do {
        Start-Sleep -Seconds 10
        $deployment = Invoke-Arm $deploymentPath
        $state = $deployment.properties.provisioningState
        if ($state -in @('Failed', 'Canceled')) {
            throw "Runtime deployment $state; ingress remains internal. Inspect deployment operations in Azure."
        }
        if ([DateTime]::UtcNow -gt $deadline) {
            throw 'Runtime deployment polling timed out; inspect the existing deployment, do not blindly resubmit.'
        }
    } until ($state -eq 'Succeeded')
}
finally {
    $parameters = $null
    $armParameters = $null
    $internalToken = $null
    $existingSecrets = $null
}
Write-Host 'Runtime and EasyAuth deployed with INTERNAL ingress. Configure the public callback URI, then run Publish-Azure.ps1.'
