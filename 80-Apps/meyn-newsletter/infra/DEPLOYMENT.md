# HSE Newsletter Manager - Azure Deployment Guide

## Architecture Overview

```
Azure Repos (Git) --> Azure DevOps Pipeline --> ACR --> Azure Container Apps
                            |
                      Microsoft Defender
                      (Vulnerability Scan)
                            |
                        Renovate
                      (Dependency Updates)
```

## Prerequisites

1. **Azure Subscription** with permissions to create:
   - Resource Groups
   - Azure Container Registry
   - Azure Container Apps
   - Log Analytics Workspace

2. **Azure DevOps Organization** with:
   - Project created
   - Azure Repos enabled
   - Pipelines enabled

3. **Azure AD App Registration** (already created for MSAL):
   - Note the Client ID and Tenant ID
   - Update redirect URIs after deployment

## Step 1: Initial Azure Infrastructure

### Option A: Using Shell Script (Recommended for quick setup)

```bash
# Login to Azure
az login

# Make script executable
chmod +x infra/deploy-azure.sh

# Run the deployment script
./infra/deploy-azure.sh
```

### Option B: Using Bicep (Infrastructure as Code)

```bash
# Login to Azure
az login

# Create resource group
az group create --name rg-hse-newsletter --location westeurope

# Deploy infrastructure
az deployment group create \
  --resource-group rg-hse-newsletter \
  --template-file infra/main.bicep \
  --parameters \
    azureClientId='<your-client-id>' \
    azureTenantId='<your-tenant-id>' \
    oneDriveFolderItemId='<your-folder-id>'
```

## Step 2: Azure DevOps Setup

### 2.1 Create Service Connections

1. **Docker Registry Connection (ACR)**:
   - Go to Project Settings > Service Connections
   - New > Docker Registry
   - Registry type: Azure Container Registry
   - Select your subscription and ACR
   - Name: `acr-service-connection`

2. **Azure Resource Manager Connection**:
   - New > Azure Resource Manager
   - Service principal (automatic)
   - Select subscription and resource group
   - Name: `azure-subscription-connection`

### 2.2 Configure Pipeline Variables

In Azure DevOps > Pipelines > Library > Variable Groups:

Create a variable group named `hse-newsletter-vars`:

| Variable | Value | Secret |
|----------|-------|--------|
| NEXT_PUBLIC_MSAL_CLIENT_ID | `74d635f9-b2bf-4a4a-bfdf-a57e4ddccf5b` | Yes |
| NEXT_PUBLIC_MSAL_TENANT_ID | `a619d00a-6445-4380-98ba-25dca8b52830` | No |
| NEXT_PUBLIC_ONEDRIVE_DRIVE_ID | `b!UcISJPtO7UOy12RCpz5O_f28tYGSHtxCiXLL57oCo5MTHN9SpdLlQJUzh8ae8cIf` | Yes |
| NEXT_PUBLIC_ONEDRIVE_ITEM_ID | `012AEBPGDPUXHGXUKC3VBZUJI5YGN4QWYF` | Yes |
| NEXT_PUBLIC_ONEDRIVE_FOLDER_PATH | `/Safety Bulletin` | No |

### 2.3 Import Repository

1. Azure Repos > Import repository
2. Import from your current Git location
3. Or push directly:
   ```bash
   git remote add azure https://dev.azure.com/<org>/<project>/_git/<repo>
   git push azure main
   ```

### 2.4 Create Pipeline

1. Pipelines > Create Pipeline
2. Select Azure Repos Git
3. Select your repository
4. Select "Existing Azure Pipelines YAML file"
5. Path: `/azure-pipelines.yml`
6. Run the pipeline

## Step 3: Update Azure AD App Registration

After deployment, update your Azure AD App Registration:

1. Go to Azure Portal > Azure Active Directory > App Registrations
2. Select your HSE Newsletter Manager app
3. Go to Authentication > Add Platform > Single-page application
4. Add redirect URI: `https://<your-container-app-fqdn>`
5. Save

## Step 4: Enable Renovate for Dependency Updates

Renovate is configured via `renovate.json`. To enable:

### For Azure DevOps:

1. Install Renovate from Azure DevOps Marketplace:
   https://marketplace.visualstudio.com/items?itemName=renovate.renovate

2. Configure pipeline for Renovate:
   - Create a new pipeline from the Renovate extension
   - Or schedule manually via cron

### Configuration highlights:
- Runs weekly on Monday mornings (Europe/Warsaw timezone)
- Groups related dependencies (React, Next.js, Microsoft, etc.)
- Auto-merges security patches
- Creates PRs for major updates requiring review

## Step 5: Microsoft Defender for Containers

Defender is automatically enabled by the deployment script. It provides:

- **Vulnerability scanning** on image push to ACR
- **Runtime threat detection** in Container Apps
- **Security recommendations** in Azure Security Center

View results in:
- Azure Portal > Security Center > Defender for Cloud
- ACR > Your registry > Security

## Environment Variables Reference

| Variable | Description | Where to Set |
|----------|-------------|--------------|
| NEXT_PUBLIC_MSAL_CLIENT_ID | Azure AD application client ID | Azure DevOps Variables |
| NEXT_PUBLIC_MSAL_TENANT_ID | Azure AD tenant ID | Azure DevOps Variables |
| NEXT_PUBLIC_ONEDRIVE_DRIVE_ID | OneDrive drive ID | Azure DevOps Variables |
| NEXT_PUBLIC_ONEDRIVE_ITEM_ID | OneDrive folder item ID | Azure DevOps Variables |
| NEXT_PUBLIC_ONEDRIVE_FOLDER_PATH | OneDrive folder path (fallback) | Azure DevOps Variables |

## Scaling Configuration

The Container App is configured with:
- **Min replicas**: 0 (scales to zero when idle)
- **Max replicas**: 3
- **CPU**: 0.5 cores
- **Memory**: 1GB
- **Scale trigger**: HTTP requests (10 concurrent)

Modify in `azure-pipelines.yml` or `infra/main.bicep` as needed.

## Monitoring & Logs

### View Logs
```bash
az containerapp logs show \
  --name ca-hse-newsletter \
  --resource-group rg-hse-newsletter \
  --follow
```

### Log Analytics Queries
```kusto
// Application errors
ContainerAppConsoleLogs_CL
| where Log_s contains "error" or Log_s contains "Error"
| order by TimeGenerated desc
| take 100

// Request metrics
ContainerAppSystemLogs_CL
| where Type_s == "request"
| summarize count() by bin(TimeGenerated, 1h)
```

## Troubleshooting

### Pipeline Fails at Docker Build
- Check Dockerfile syntax
- Ensure all dependencies are in package.json
- Verify pnpm-lock.yaml is committed

### Container App Not Starting
```bash
az containerapp revision list \
  --name ca-hse-newsletter \
  --resource-group rg-hse-newsletter \
  --output table
```

### Authentication Issues
- Verify redirect URI matches exactly
- Check Client ID and Tenant ID
- Ensure app registration has correct API permissions

## Cost Estimation

| Resource | SKU | Estimated Monthly Cost |
|----------|-----|------------------------|
| Container Registry | Basic | ~$5 |
| Container Apps | Consumption | ~$0-20 (pay per use) |
| Log Analytics | Pay-as-you-go | ~$2-5 |
| **Total** | | **~$7-30/month** |

*Costs vary based on usage. Container Apps scale to zero when idle.*
