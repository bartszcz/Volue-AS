// Azure Bicep template for HSE Newsletter Manager
// Deploy with: az deployment group create --resource-group rg-hse-newsletter --template-file main.bicep

@description('Location for all resources')
param location string = resourceGroup().location

@description('Base name for resources')
param baseName string = 'hsenewsletter'

@description('Azure AD Client ID for MSAL authentication')
@secure()
param azureClientId string

@description('Azure AD Tenant ID')
@secure()
param azureTenantId string

@description('OneDrive Folder Item ID')
@secure()
param oneDriveFolderItemId string

// Variables
var acrName = '${baseName}acr'
var logAnalyticsName = 'law-${baseName}'
var containerAppEnvName = 'cae-${baseName}'
var containerAppName = 'ca-${baseName}'

// Log Analytics Workspace
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Azure Container Registry
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
}

// Container Apps Environment
resource containerAppEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: containerAppEnvName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

// Container App
resource containerApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: containerAppName
  location: location
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 3000
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: acr.properties.loginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: [
        {
          name: 'acr-password'
          value: acr.listCredentials().passwords[0].value
        }
        {
          name: 'azure-client-id'
          value: azureClientId
        }
        {
          name: 'azure-tenant-id'
          value: azureTenantId
        }
        {
          name: 'onedrive-folder-id'
          value: oneDriveFolderItemId
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'hse-newsletter-manager'
          image: 'mcr.microsoft.com/k8se/quickstart:latest' // Placeholder, will be updated by CI/CD
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'NEXT_PUBLIC_AZURE_CLIENT_ID'
              secretRef: 'azure-client-id'
            }
            {
              name: 'NEXT_PUBLIC_AZURE_TENANT_ID'
              secretRef: 'azure-tenant-id'
            }
            {
              name: 'NEXT_PUBLIC_ONEDRIVE_FOLDER_ITEM_ID'
              secretRef: 'onedrive-folder-id'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 3
        rules: [
          {
            name: 'http-scaling'
            http: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
    }
  }
}

// Outputs
output acrLoginServer string = acr.properties.loginServer
output containerAppFqdn string = containerApp.properties.configuration.ingress.fqdn
output containerAppUrl string = 'https://${containerApp.properties.configuration.ingress.fqdn}'
