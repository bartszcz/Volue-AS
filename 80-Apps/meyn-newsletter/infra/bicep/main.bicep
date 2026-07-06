// HSE Newsletter Manager - Azure Infrastructure as Code
// Deploys: Azure Static Web App + configures settings
//
// Usage (single line in PowerShell):
//   az deployment group create --resource-group rg-hse-newsletter --template-file infra/bicep/main.bicep --parameters appName=hse-newsletter-manager location=westeurope msalClientId=YOUR_CLIENT_ID msalTenantId=YOUR_TENANT_ID

@description('Name of the Static Web App')
param appName string = 'hse-newsletter-manager'

@description('Azure region for the Static Web App')
param location string = resourceGroup().location

@description('SKU for the Static Web App')
@allowed(['Free', 'Standard'])
param sku string = 'Free'

@description('Azure AD Client ID for MSAL authentication')
param msalClientId string = ''

@description('Azure AD Tenant ID for MSAL authentication')
param msalTenantId string = ''

@description('OneDrive folder path for Safety bulletin files')
param oneDriveFolderPath string = '/Safety bulletin'

@description('Azure DevOps repository URL (required by Azure, but actual deploys use the pipeline token)')
param repositoryUrl string = 'https://dev.azure.com/yourorg/HSE-Newsletter-Manager/_git/HSE-Newsletter-Manager'

// ──────────────────────────────────────────────
// Static Web App
// ──────────────────────────────────────────────
// Azure requires a repositoryUrl even for pipeline-based deploys.
// The URL is informational only -- actual deployment is handled
// by the Azure DevOps pipeline using the SWA deployment token.
resource staticWebApp 'Microsoft.Web/staticSites@2023-12-01' = {
  name: appName
  location: location
  sku: {
    name: sku
    tier: sku
  }
  properties: {
    repositoryUrl: repositoryUrl
    branch: 'main'
    buildProperties: {
      skipGithubActionWorkflowGeneration: true
    }
  }
  tags: {
    project: 'hse-newsletter-manager'
    environment: 'production'
    managedBy: 'bicep'
  }
}

// ──────────────────────────────────────────────
// App Settings (environment variables)
// ──────────────────────────────────────────────
resource appSettings 'Microsoft.Web/staticSites/config@2023-12-01' = {
  parent: staticWebApp
  name: 'appsettings'
  properties: {
    NEXT_PUBLIC_MSAL_CLIENT_ID: msalClientId
    NEXT_PUBLIC_MSAL_TENANT_ID: msalTenantId
    NEXT_PUBLIC_ONEDRIVE_FOLDER_PATH: oneDriveFolderPath
  }
}

// ──────────────────────────────────────────────
// Outputs
// ──────────────────────────────────────────────
@description('The default hostname of the Static Web App')
output defaultHostname string = staticWebApp.properties.defaultHostname

@description('The resource ID of the Static Web App')
output staticWebAppId string = staticWebApp.id

// To get the deployment token for the Azure DevOps pipeline, run:
//   az staticwebapp secrets list --name hse-newsletter-manager --query "properties.apiKey" -o tsv
