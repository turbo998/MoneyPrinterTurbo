targetScope = 'resourceGroup'

param name string
param location string
param tags object
param storageAccountResourceId string

var services = [
  'blob'
  'queue'
  'table'
]

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${name}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.247.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'aca-infrastructure'
        properties: {
          addressPrefix: '10.247.0.0/23'
          delegations: [
            {
              name: 'container-apps'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: 'storage-private-endpoints'
        properties: {
          addressPrefix: '10.247.2.0/27'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource zones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for service in services: {
  name: 'privatelink.${service}.${environment().suffixes.storage}'
  location: 'global'
  tags: tags
}]
resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (service, index) in services: {
  parent: zones[index]
  name: '${name}-vnet'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}]
resource endpoints 'Microsoft.Network/privateEndpoints@2024-05-01' = [for service in services: {
  name: '${name}-pe-${service}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: '${vnet.id}/subnets/storage-private-endpoints'
    }
    privateLinkServiceConnections: [
      {
        name: 'storage-${service}'
        properties: {
          privateLinkServiceId: storageAccountResourceId
          groupIds: [
            service
          ]
        }
      }
    ]
  }
}]
resource zoneGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = [for (service, index) in services: {
  parent: endpoints[index]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: service
        properties: {
          privateDnsZoneId: zones[index].id
        }
      }
    ]
  }
}]

output vnetId string = vnet.id
output infrastructureSubnetId string = '${vnet.id}/subnets/aca-infrastructure'
output privateEndpointSubnetId string = '${vnet.id}/subnets/storage-private-endpoints'
output privateEndpointIds array = [for (service, index) in services: endpoints[index].id]
output privateDnsZoneIds array = [for (service, index) in services: zones[index].id]
output privateDnsLinkIds array = [for (service, index) in services: links[index].id]
