targetScope = 'subscription'

@minLength(3)
@maxLength(32)
param environmentName string
param location string
param resourceGroupName string = 'rg-${environmentName}'
param textResourceGroup string
param textAccountName string
param imageResourceGroup string
param imageAccountName string
param speechResourceGroup string
param speechAccountName string

var tags = {
  'azd-env-name': environmentName
  application: 'MoneyPrinterTurbo'
  workload: 'poc'
}

resource group 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module foundation 'modules/foundation.bicep' = {
  name: '${environmentName}-foundation'
  scope: group
  params: {
    name: environmentName
    location: location
    tags: tags
  }
}

module textInference 'modules/inference-role.bicep' = {
  name: '${environmentName}-text-rbac'
  scope: resourceGroup(textResourceGroup)
  params: {
    accountName: textAccountName
    principalId: foundation.outputs.workerPrincipalId
    roleDefinitionGuid: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
  }
}

module imageInference 'modules/inference-role.bicep' = {
  name: '${environmentName}-image-rbac'
  scope: resourceGroup(imageResourceGroup)
  params: {
    accountName: imageAccountName
    principalId: foundation.outputs.workerPrincipalId
    roleDefinitionGuid: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
  }
}

module speechInference 'modules/inference-role.bicep' = {
  name: '${environmentName}-speech-rbac'
  scope: resourceGroup(speechResourceGroup)
  params: {
    accountName: speechAccountName
    principalId: foundation.outputs.workerPrincipalId
    roleDefinitionGuid: 'f2dc8367-1007-4938-bd23-fe263f013447'
  }
}

output AZURE_RESOURCE_GROUP string = group.name
output AZURE_LOCATION string = location
output AZURE_CONTAINER_REGISTRY_NAME string = foundation.outputs.registryName
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = foundation.outputs.registryServer
output AZURE_CONTAINER_APPS_ENVIRONMENT_ID string = foundation.outputs.environmentId
output AZURE_LOG_ANALYTICS_WORKSPACE_ID string = foundation.outputs.workspaceId
output MPT_STORAGE_ACCOUNT string = foundation.outputs.storageAccount
output MPT_WEB_IDENTITY_ID string = foundation.outputs.webIdentityId
output MPT_WEB_CLIENT_ID string = foundation.outputs.webClientId
output MPT_WORKER_IDENTITY_ID string = foundation.outputs.workerIdentityId
output MPT_WORKER_CLIENT_ID string = foundation.outputs.workerClientId
output MPT_WEB_APP_NAME string = foundation.outputs.webAppName
output MPT_WORKER_JOB_NAME string = foundation.outputs.workerJobName
output MPT_MAINTENANCE_JOB_NAME string = foundation.outputs.maintenanceJobName
output MPT_NETWORK_MODE string = 'storage-private-endpoints-v1'
output MPT_STORAGE_RESOURCE_ID string = foundation.outputs.storageResourceId
output AZURE_VIRTUAL_NETWORK_ID string = foundation.outputs.vnetId
output MPT_ACA_SUBNET_ID string = foundation.outputs.infrastructureSubnetId
output MPT_PRIVATE_ENDPOINT_SUBNET_ID string = foundation.outputs.privateEndpointSubnetId
output MPT_STORAGE_PRIVATE_ENDPOINT_IDS array = foundation.outputs.privateEndpointIds
output MPT_PRIVATE_DNS_ZONE_IDS array = foundation.outputs.privateDnsZoneIds
output MPT_PRIVATE_DNS_LINK_IDS array = foundation.outputs.privateDnsLinkIds
