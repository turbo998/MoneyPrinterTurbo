targetScope = 'resourceGroup'

param name string
param location string
param tags object

var suffix = uniqueString(subscription().id, resourceGroup().id, name)
var stem = 'mpt-${take(suffix, 8)}'

resource webIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${stem}-web'
  location: location
  tags: tags
}
resource workerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${stem}-worker'
  location: location
  tags: tags
}
resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'crmpt${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}
var pullPrincipalIds = [
  webIdentity.properties.principalId
  workerIdentity.properties.principalId
]
var pullIdentityIds = [
  webIdentity.id
  workerIdentity.id
]
resource pullRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for index in range(0, 2): {
  name: guid(registry.id, pullIdentityIds[index], 'acrpull')
  scope: registry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: pullPrincipalIds[index]
    principalType: 'ServicePrincipal'
  }
}]
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${stem}-logs'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    workspaceCapping: {
      dailyQuotaGb: 1
    }
  }
}
resource environment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: '${stem}-env-vnet'
  location: location
  tags: tags
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: network.outputs.infrastructureSubnetId
      internal: false
    }
    appLogsConfiguration: {
      destination: 'azure-monitor'
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}
resource environmentLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'logs'
  scope: environment
  properties: {
    workspaceId: workspace.id
    logs: [
      {
        category: 'ContainerAppConsoleLogs'
        enabled: true
      }
      {
        category: 'ContainerAppSystemLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}
module storage 'storage.bicep' = {
  name: 'storage'
  params: {
    name: 'stmpt${suffix}'
    location: location
    tags: tags
    workspaceId: workspace.id
    principalIds: [
      webIdentity.properties.principalId
      workerIdentity.properties.principalId
    ]
  }
}

module network 'network.bicep' = {
  name: 'private-network'
  params: {
    name: stem
    location: location
    tags: tags
    storageAccountResourceId: storage.outputs.resourceId
  }
}

output registryName string = registry.name
output registryServer string = registry.properties.loginServer
output environmentId string = environment.id
output workspaceId string = workspace.id
output storageAccount string = storage.outputs.storageAccountName
output webIdentityId string = webIdentity.id
output webClientId string = webIdentity.properties.clientId
output workerIdentityId string = workerIdentity.id
output workerPrincipalId string = workerIdentity.properties.principalId
output workerClientId string = workerIdentity.properties.clientId
output webAppName string = '${stem}-web-vnet'
output workerJobName string = '${stem}-render-vnet'
output maintenanceJobName string = '${stem}-maintain-vnet'
output storageResourceId string = storage.outputs.resourceId
output vnetId string = network.outputs.vnetId
output infrastructureSubnetId string = network.outputs.infrastructureSubnetId
output privateEndpointSubnetId string = network.outputs.privateEndpointSubnetId
output privateEndpointIds array = network.outputs.privateEndpointIds
output privateDnsZoneIds array = network.outputs.privateDnsZoneIds
output privateDnsLinkIds array = network.outputs.privateDnsLinkIds
