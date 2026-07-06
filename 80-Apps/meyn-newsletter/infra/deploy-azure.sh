#!/bin/bash
# Azure Infrastructure Deployment Script for HSE Newsletter Manager
# Run this once to set up the initial Azure resources

set -e

# Configuration - UPDATE THESE VALUES
RESOURCE_GROUP="rg-hse-newsletter"
LOCATION="westeurope"
ACR_NAME="hsenewsletteracr"
CONTAINER_APP_ENV="cae-hse-newsletter"
CONTAINER_APP_NAME="ca-hse-newsletter"
LOG_ANALYTICS_WORKSPACE="law-hse-newsletter"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== HSE Newsletter Manager - Azure Infrastructure Setup ===${NC}"

# Check if logged in to Azure
echo -e "${YELLOW}Checking Azure CLI login status...${NC}"
if ! az account show &> /dev/null; then
    echo -e "${RED}Not logged in to Azure. Please run 'az login' first.${NC}"
    exit 1
fi

# Show current subscription
SUBSCRIPTION=$(az account show --query name -o tsv)
echo -e "${GREEN}Using subscription: $SUBSCRIPTION${NC}"

# Create Resource Group
echo -e "${YELLOW}Creating Resource Group: $RESOURCE_GROUP...${NC}"
az group create \
    --name $RESOURCE_GROUP \
    --location $LOCATION \
    --output none
echo -e "${GREEN}Resource Group created.${NC}"

# Create Azure Container Registry
echo -e "${YELLOW}Creating Azure Container Registry: $ACR_NAME...${NC}"
az acr create \
    --resource-group $RESOURCE_GROUP \
    --name $ACR_NAME \
    --sku Basic \
    --admin-enabled true \
    --output none
echo -e "${GREEN}Container Registry created.${NC}"

# Enable Microsoft Defender for Containers (for vulnerability scanning)
echo -e "${YELLOW}Enabling Microsoft Defender for Containers...${NC}"
az security pricing create \
    --name Containers \
    --tier Standard \
    --output none 2>/dev/null || echo -e "${YELLOW}Defender may already be enabled or requires additional permissions.${NC}"

# Create Log Analytics Workspace
echo -e "${YELLOW}Creating Log Analytics Workspace: $LOG_ANALYTICS_WORKSPACE...${NC}"
az monitor log-analytics workspace create \
    --resource-group $RESOURCE_GROUP \
    --workspace-name $LOG_ANALYTICS_WORKSPACE \
    --location $LOCATION \
    --output none

LOG_ANALYTICS_WORKSPACE_ID=$(az monitor log-analytics workspace show \
    --resource-group $RESOURCE_GROUP \
    --workspace-name $LOG_ANALYTICS_WORKSPACE \
    --query customerId \
    --output tsv)

LOG_ANALYTICS_KEY=$(az monitor log-analytics workspace get-shared-keys \
    --resource-group $RESOURCE_GROUP \
    --workspace-name $LOG_ANALYTICS_WORKSPACE \
    --query primarySharedKey \
    --output tsv)

echo -e "${GREEN}Log Analytics Workspace created.${NC}"

# Create Container Apps Environment
echo -e "${YELLOW}Creating Container Apps Environment: $CONTAINER_APP_ENV...${NC}"
az containerapp env create \
    --name $CONTAINER_APP_ENV \
    --resource-group $RESOURCE_GROUP \
    --location $LOCATION \
    --logs-workspace-id $LOG_ANALYTICS_WORKSPACE_ID \
    --logs-workspace-key $LOG_ANALYTICS_KEY \
    --output none
echo -e "${GREEN}Container Apps Environment created.${NC}"

# Get ACR credentials
ACR_LOGIN_SERVER=$(az acr show --name $ACR_NAME --query loginServer -o tsv)
ACR_USERNAME=$(az acr credential show --name $ACR_NAME --query username -o tsv)
ACR_PASSWORD=$(az acr credential show --name $ACR_NAME --query "passwords[0].value" -o tsv)

# Create Container App (initial deployment with placeholder image)
echo -e "${YELLOW}Creating Container App: $CONTAINER_APP_NAME...${NC}"
az containerapp create \
    --name $CONTAINER_APP_NAME \
    --resource-group $RESOURCE_GROUP \
    --environment $CONTAINER_APP_ENV \
    --image mcr.microsoft.com/k8se/quickstart:latest \
    --target-port 3000 \
    --ingress external \
    --min-replicas 0 \
    --max-replicas 3 \
    --cpu 0.5 \
    --memory 1.0Gi \
    --registry-server $ACR_LOGIN_SERVER \
    --registry-username $ACR_USERNAME \
    --registry-password $ACR_PASSWORD \
    --output none
echo -e "${GREEN}Container App created.${NC}"

# Get the FQDN
FQDN=$(az containerapp show \
    --name $CONTAINER_APP_NAME \
    --resource-group $RESOURCE_GROUP \
    --query properties.configuration.ingress.fqdn \
    --output tsv)

echo ""
echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo ""
echo -e "Container Registry: ${YELLOW}$ACR_LOGIN_SERVER${NC}"
echo -e "Container App URL:  ${YELLOW}https://$FQDN${NC}"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Set up Azure DevOps Service Connection to ACR:"
echo "   - Go to Azure DevOps > Project Settings > Service Connections"
echo "   - Add 'Docker Registry' connection to $ACR_LOGIN_SERVER"
echo ""
echo "2. Set up Azure DevOps Service Connection to Azure:"
echo "   - Add 'Azure Resource Manager' connection"
echo ""
echo "3. Add Pipeline Variables in Azure DevOps:"
echo "   - NEXT_PUBLIC_AZURE_CLIENT_ID"
echo "   - NEXT_PUBLIC_AZURE_TENANT_ID"
echo "   - NEXT_PUBLIC_ONEDRIVE_FOLDER_ITEM_ID"
echo ""
echo "4. Update Azure AD App Registration:"
echo "   - Add redirect URI: https://$FQDN"
echo ""
echo "5. Import azure-pipelines.yml to Azure DevOps Pipelines"
echo ""
