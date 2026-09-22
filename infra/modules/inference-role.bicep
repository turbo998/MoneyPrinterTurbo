targetScope = 'resourceGroup'

param accountName string
param principalId string
@allowed([
  '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
  'f2dc8367-1007-4938-bd23-fe263f013447'
])
param roleDefinitionGuid string

// Existing means no account settings, keys, or model deployments are changed.
resource account 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: accountName
}
resource inference 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, principalId, roleDefinitionGuid)
  scope: account
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionGuid)
  }
}
