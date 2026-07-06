using './main.bicep'

// Update these values before deployment
param location = 'westeurope'
param baseName = 'hsenewsletter'

// These should be passed securely via Azure DevOps pipeline variables
// or Azure Key Vault references
param azureClientId = '' // Set in pipeline
param azureTenantId = '' // Set in pipeline  
param oneDriveFolderItemId = '' // Set in pipeline
