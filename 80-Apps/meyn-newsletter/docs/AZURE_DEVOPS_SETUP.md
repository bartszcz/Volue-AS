# Azure DevOps Project Setup Guide

## Project Overview

**HSE Newsletter Manager** - A web application for managing and distributing HSE (Health, Safety, Environment) newsletters. The app integrates with Microsoft 365/OneDrive for file management and uses Azure AD for authentication.

### Architecture Summary

```
Local Development          Azure DevOps              Azure Cloud
─────────────────         ─────────────             ───────────
     Code                    Repos                  Container Registry
       │                       │                         │
       └──── git push ────────►│                         │
                               │                         │
                           Pipeline ──── build ─────────►│
                               │                         │
                               │                    Container Apps
                               └──── deploy ────────────►│
                                                         │
                                                    Live App
                                              (ca-hse-newsletter)
```

### Key URLs

| Resource | URL |
|----------|-----|
| Live Application | https://ca-hse-newsletter.braveplant-83c6ba92.westeurope.azurecontainerapps.io |
| Azure DevOps Project | https://dev.azure.com/Meyn-Poland/HSE-Newsletter-Manager |
| Azure Portal (Resources) | https://portal.azure.com → Resource Group: rg-hse-newsletter |

---

## Pipelines

### Build and Deploy Pipeline (HSE-Newsletter-Manager (2))

**Purpose:** Builds and deploys the application to Azure Container Apps.

**Triggers:**
- Automatically runs on every push to `main` branch
- Can be manually triggered from Azure DevOps

**Stages:**
1. Build Docker image (~55 seconds)
2. Push to Azure Container Registry (~14 seconds)
3. Deploy to Container Apps (~27 seconds)

**Total Time:** ~2 minutes

### Renovate Pipeline (HSE-Newsletter-Manager (3))

**Purpose:** Automatically checks for and applies security updates.

**Schedule:** 
- Runs daily at 6 AM (Warsaw time)
- Can be manually triggered

**What it does:**
- Scans all dependencies for security vulnerabilities
- Creates Pull Requests for updates
- Auto-merges critical security patches

---

## How to Make Changes

### For Developers

1. Clone the repository:
   ```bash
   git clone https://dev.azure.com/Meyn-Poland/HSE-Newsletter-Manager/_git/HSE-Newsletter-Manager
   ```

2. Make your changes locally

3. Commit and push:
   ```bash
   git add .
   git commit -m "Description of changes"
   git push origin main
   ```

4. The pipeline automatically builds and deploys (watch in Azure DevOps → Pipelines)

### For Non-Developers

1. Go to Azure DevOps → Repos
2. Navigate to the file you want to edit
3. Click Edit
4. Make changes
5. Click Commit
6. The pipeline will automatically deploy your changes

---

## Monitoring

### View Application Logs

**Option 1: Azure Portal**
1. Go to https://portal.azure.com
2. Search for "ca-hse-newsletter"
3. Click on the Container App
4. Go to "Log stream" in the left menu

**Option 2: Azure CLI**
```bash
az containerapp logs show --name ca-hse-newsletter --resource-group rg-hse-newsletter --follow
```

### View Pipeline Status

1. Go to Azure DevOps → Pipelines
2. Click on the pipeline to see recent runs
3. Green = Success, Red = Failed

### View Security Alerts

1. Go to Azure Portal → Microsoft Defender for Cloud
2. Check for any security recommendations

---

## Troubleshooting

### Pipeline Failed

1. Go to Azure DevOps → Pipelines
2. Click on the failed run
3. Click on the failed stage to see error logs
4. Common issues:
   - **Timeout:** Pipeline took too long (rare now)
   - **Build error:** Code has syntax errors
   - **Deploy error:** Azure resource issues

### Application Not Working

1. Check if deployment succeeded (Azure DevOps → Pipelines)
2. Check application logs (Azure Portal → ca-hse-newsletter → Log stream)
3. Verify Azure AD redirect URIs are correct
4. Check environment variables in Variable Group

### Security Update Failed

1. Go to Azure DevOps → Pipelines → HSE-Newsletter-Manager (3)
2. Check the Renovate pipeline logs
3. If a PR was created, review and merge manually

---

## Environment Variables

Stored in: Azure DevOps → Pipelines → Library → hse-newsletter-vars

| Variable | Purpose | Secret |
|----------|---------|--------|
| NEXT_PUBLIC_MSAL_CLIENT_ID | Azure AD app ID for authentication | Yes |
| NEXT_PUBLIC_MSAL_TENANT_ID | Azure AD tenant ID | No |
| NEXT_PUBLIC_ONEDRIVE_DRIVE_ID | OneDrive drive identifier | Yes |
| NEXT_PUBLIC_ONEDRIVE_ITEM_ID | OneDrive folder item ID | Yes |
| NEXT_PUBLIC_ONEDRIVE_FOLDER_PATH | OneDrive folder path | No |
| RENOVATE_TOKEN | Personal Access Token for Renovate | Yes |

**Never share these values publicly!**

---

## Azure Resources

| Resource | Name | Purpose |
|----------|------|---------|
| Resource Group | rg-hse-newsletter | Container for all resources |
| Container Registry | hsenewsletteracr | Stores Docker images |
| Container App | ca-hse-newsletter | Runs the application |
| Container App Environment | cae-hse-newsletter | Hosting environment |
| Log Analytics | law-hse-newsletter | Logs and monitoring |

---

## Contacts & Support

For issues with:
- **Application code:** Check this repository's issues
- **Azure infrastructure:** Contact Azure administrator
- **Azure DevOps:** Contact DevOps team lead
