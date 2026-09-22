targetScope = 'resourceGroup'

param name string
param location string
param tags object
param environmentId string
param registryServer string
param containerImage string
param revisionSuffix string
param identityId string
param identityClientId string
param settings object
param tenantId string
param entraClientId string
param allowedObjectIds array
@secure()
param entraClientSecret string
@secure()
param internalApiToken string

var env = concat(map(items(settings), entry => {
  name: entry.key
  value: entry.value
}), [
  {
    name: 'AZURE_CLIENT_ID'
    value: identityClientId
  }
  {
    name: 'MPT_INTERNAL_API_URL'
    value: 'http://127.0.0.1:8080'
  }
  {
    name: 'MPT_INTERNAL_API_TOKEN'
    secretRef: 'internal-api-token'
  }
])
resource web 'Microsoft.App/containerApps@2025-01-01' = {
  name: name
  location: location
  tags: union(tags, {
    'azd-service-name': 'web'
  })
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
      activeRevisionsMode: 'Single'
      // Public ingress is enabled ONLY by Publish-Azure.ps1 after live auth checks.
      ingress: {
        external: false
        targetPort: 8501
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: registryServer
          identity: identityId
        }
      ]
      secrets: [
        {
          name: 'internal-api-token'
          value: internalApiToken
        }
        {
          name: 'entra-client-secret'
          value: entraClientSecret
        }
      ]
    }
    template: {
      revisionSuffix: revisionSuffix
      scale: {
        minReplicas: 0
        maxReplicas: 1
        rules: [
          {
            name: 'http'
            http: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
      containers: [
        {
          name: 'web'
          image: containerImage
          command: [
            'streamlit'
          ]
          args: [
            'run'
            'webui/Main.py'
            '--server.address=0.0.0.0'
            '--server.port=8501'
            '--browser.gatherUsageStats=false'
          ]
          env: env
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          probes: [
            {
              type: 'Readiness'
              httpGet: {
                path: '/_stcore/health'
                port: 8501
              }
              initialDelaySeconds: 10
              periodSeconds: 10
              timeoutSeconds: 5
              failureThreshold: 6
            }
            {
              type: 'Liveness'
              httpGet: {
                path: '/_stcore/health'
                port: 8501
              }
              initialDelaySeconds: 60
              periodSeconds: 30
              timeoutSeconds: 5
              failureThreshold: 6
            }
          ]
        }
        {
          name: 'api'
          image: containerImage
          command: [
            'python'
          ]
          args: [
            '-m'
            'uvicorn'
            'app.cloud.api:app'
            '--host'
            '127.0.0.1'
            '--port'
            '8080'
          ]
          env: env
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
        }
      ]
    }
  }
}
resource auth 'Microsoft.App/containerApps/authConfigs@2025-01-01' = {
  parent: web
  name: 'current'
  properties: {
    platform: {
      enabled: true
    }
    globalValidation: {
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureActiveDirectory'
      excludedPaths: []
    }
    httpSettings: {
      requireHttps: true
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: entraClientId
          clientSecretSettingName: 'entra-client-secret'
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [
            entraClientId
            'api://${entraClientId}'
          ]
          defaultAuthorizationPolicy: {
            allowedPrincipals: {
              identities: allowedObjectIds
            }
          }
        }
      }
    }
    login: {
      tokenStore: {
        enabled: false
      }
      nonce: {
        validateNonce: true
      }
    }
  }
}
output resourceId string = web.id
output fqdn string = web.properties.configuration.ingress.fqdn
