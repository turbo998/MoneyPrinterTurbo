targetScope = 'resourceGroup'

param location string = resourceGroup().location
param environmentName string
param environmentId string
param registryServer string
@description('Immutable ACR image reference: registry/repository@sha256:digest.')
@minLength(20)
param containerImage string
@minLength(1)
@maxLength(64)
param revisionSuffix string
param storageAccount string
param webAppName string
param workerJobName string
param maintenanceJobName string
param webIdentityId string
param webClientId string
param workerIdentityId string
param workerClientId string
@minLength(36)
param tenantId string
@minLength(36)
param entraClientId string
@minLength(1)
param allowedObjectIds array
@secure()
@minLength(1)
param entraClientSecret string
@secure()
@minLength(43)
param internalApiToken string
param textEndpoint string
param textDeployment string
param imageEndpoint string
param imageDeployment string
param speechEndpoint string
@description('Full existing Speech account resource ID; required even when the SDK uses token_credential.')
@minLength(1)
param speechResourceId string
param speechRegion string

var tags = {
  'azd-env-name': environmentName
  application: 'MoneyPrinterTurbo'
  workload: 'poc'
}
var settings = {
  MPT_CLOUD_MODE: '1'
  MPT_STORAGE_ACCOUNT: storageAccount
  MPT_TENANT_ID: tenantId
  MPT_ALLOWED_OIDS: join(allowedObjectIds, ',')
  MPT_TEXT_ENDPOINT: textEndpoint
  MPT_TEXT_DEPLOYMENT: textDeployment
  MPT_IMAGE_ENDPOINT: imageEndpoint
  MPT_IMAGE_DEPLOYMENT: imageDeployment
  MPT_SPEECH_ENDPOINT: speechEndpoint
  MPT_SPEECH_RESOURCE_ID: speechResourceId
  MPT_SPEECH_REGION: speechRegion
}

module web 'modules/web.bicep' = {
  name: 'web'
  params: {
    name: webAppName
    location: location
    tags: tags
    environmentId: environmentId
    registryServer: registryServer
    containerImage: containerImage
    revisionSuffix: revisionSuffix
    identityId: webIdentityId
    identityClientId: webClientId
    settings: settings
    internalApiToken: internalApiToken
    entraClientSecret: entraClientSecret
    entraClientId: entraClientId
    tenantId: tenantId
    allowedObjectIds: allowedObjectIds
  }
}
module worker 'modules/job.bicep' = {
  name: 'worker'
  params: {
    name: workerJobName
    location: location
    tags: tags
    environmentId: environmentId
    registryServer: registryServer
    containerImage: containerImage
    identityId: workerIdentityId
    identityClientId: workerClientId
    settings: settings
    storageAccount: storageAccount
    maintenance: false
  }
}
module maintenance 'modules/job.bicep' = {
  name: 'maintenance'
  params: {
    name: maintenanceJobName
    location: location
    tags: tags
    environmentId: environmentId
    registryServer: registryServer
    containerImage: containerImage
    identityId: workerIdentityId
    identityClientId: workerClientId
    settings: settings
    storageAccount: storageAccount
    maintenance: true
  }
}
output webAppResourceId string = web.outputs.resourceId
output internalWebHost string = web.outputs.fqdn
output environmentResourceId string = environmentId
output workerJobResourceId string = worker.outputs.resourceId
output maintenanceJobResourceId string = maintenance.outputs.resourceId
