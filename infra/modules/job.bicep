targetScope = 'resourceGroup'

param name string
param location string
param tags object
param environmentId string
param registryServer string
param containerImage string
param identityId string
param identityClientId string
param settings object
param storageAccount string
param maintenance bool

resource job 'Microsoft.App/jobs@2025-01-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: maintenance ? 'Schedule' : 'Event'
      replicaTimeout: maintenance ? 240 : 3600
      replicaRetryLimit: 0
      registries: [
        {
          server: registryServer
          identity: identityId
        }
      ]
      scheduleTriggerConfig: maintenance ? {
        cronExpression: '*/5 * * * *'
        parallelism: 1
        replicaCompletionCount: 1
      } : null
      eventTriggerConfig: maintenance ? null : {
        parallelism: 1
        replicaCompletionCount: 1
        scale: {
          minExecutions: 0
          maxExecutions: 1
          pollingInterval: 30
          rules: [
            {
              name: 'tasks'
              type: 'azure-queue'
              identity: identityId
              metadata: {
                accountName: storageAccount
                queueName: 'tasks'
                queueLength: '1'
                activationQueueLength: '0'
              }
            }
          ]
        }
      }
    }
    template: {
      containers: [
        {
          name: maintenance ? 'maintenance' : 'worker'
          image: containerImage
          command: [
            'python'
          ]
          args: maintenance ? [
            '-m'
            'app.cloud.worker'
            'maintain'
          ] : [
            '-m'
            'app.cloud.worker'
          ]
          env: concat(map(items(settings), entry => {
            name: entry.key
            value: entry.value
          }), [
            {
              name: 'AZURE_CLIENT_ID'
              value: identityClientId
            }
          ])
          resources: {
            cpu: maintenance ? json('0.5') : 2
            memory: maintenance ? '1Gi' : '4Gi'
          }
        }
      ]
    }
  }
}

output resourceId string = job.id
