# HSE Newsletter Manager

A modern web application for managing and distributing Health, Safety, and Environment (HSE) newsletters. The application integrates with Microsoft 365/OneDrive for document management and uses Azure Active Directory for secure authentication.

## 🚀 Live Application

**Production URL:** https://ca-hse-newsletter.braveplant-83c6ba92.westeurope.azurecontainerapps.io

## 📋 Features

- **Microsoft 365 Integration**: Seamlessly manage newsletters stored in OneDrive
- **Azure AD Authentication**: Secure login with organizational accounts
- **Responsive Design**: Works on desktop, tablet, and mobile devices
- **Automated Deployments**: CI/CD pipeline for continuous updates
- **Security Updates**: Automated dependency updates via Renovate
- **Monitoring**: Real-time logs and health monitoring via Azure Log Analytics

## 🛠️ Tech Stack

| Layer | Technologies |
|-------|--------------|
| **Frontend** | Next.js 16, React 19, TypeScript |
| **Styling** | Tailwind CSS, shadcn/ui |
| **Authentication** | Azure AD (MSAL) |
| **Cloud Platform** | Microsoft Azure |
| **Container Runtime** | Azure Container Apps |
| **Registry** | Azure Container Registry (ACR) |
| **CI/CD** | Azure DevOps Pipelines |
| **Dependency Updates** | Renovate |
| **Monitoring** | Azure Log Analytics |

## 📦 Prerequisites

Before you can work on this project, ensure you have:

- **Git** - Version control ([Download](https://git-scm.com/download/win))
- **Node.js 24+** - Runtime ([Download](https://nodejs.org/))
- **pnpm** - Package manager (install via `npm install -g pnpm`)
- **Visual Studio Code** - Editor (optional but recommended) ([Download](https://code.visualstudio.com/))
- **Azure CLI** - Azure tools (optional for deployment) ([Download](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli))

Verify installation:
```bash
git --version
node --version
pnpm --version
```

## 🚀 Quick Start

### 1. Clone the Repository

```bash
cd C:\Projects
git clone https://dev.azure.com/Meyn-Poland/HSE-Newsletter-Manager/_git/HSE-Newsletter-Manager
cd HSE-Newsletter-Manager
```

### 2. Install Dependencies

```bash
pnpm install
```

### 3. Set Up Environment Variables

Create a `.env.local` file in the project root:

```bash
cp .env.example .env.local
```

Add your local development values (ask your team lead for the actual values):

```env
NEXT_PUBLIC_MSAL_CLIENT_ID=your_client_id
NEXT_PUBLIC_MSAL_TENANT_ID=your_tenant_id
NEXT_PUBLIC_ONEDRIVE_DRIVE_ID=your_drive_id
NEXT_PUBLIC_ONEDRIVE_ITEM_ID=your_item_id
NEXT_PUBLIC_ONEDRIVE_FOLDER_PATH=/Safety Bulletin
```

### 4. Run Locally

```bash
pnpm dev
```

The app will be available at: http://localhost:3000

### 5. Build for Production

```bash
pnpm build
pnpm start
```

## 📁 Project Structure

```
├── app/                    # Next.js app directory
│   ├── layout.tsx         # Root layout
│   ├── page.tsx           # Home page
│   └── api/               # API routes
├── components/            # React components
│   └── ui/                # shadcn/ui components
├── public/                # Static assets
├── docs/                  # Documentation
│   ├── AZURE_DEVOPS_SETUP.md
│   └── TEAM_ONBOARDING.md
├── Dockerfile             # Container image definition
├── azure-pipelines.yml    # CI/CD pipeline
├── renovate-pipeline.yml  # Security updates pipeline
├── renovate.json          # Renovate configuration
├── package.json           # Dependencies
├── tsconfig.json          # TypeScript config
└── tailwind.config.ts     # Tailwind CSS config
```

## 🔄 Development Workflow

### Making Changes

```bash
# Create a feature branch
git checkout -b feature/your-feature-name

# Make your changes...

# Commit and push
git add .
git commit -m "feat: Add your feature description"
git push origin feature/your-feature-name
```

### Code Review & Merging

1. Push your branch to Azure Repos
2. Create a Pull Request (PR) in Azure DevOps
3. Wait for code review (1 approval required)
4. Merge to `main` branch
5. Pipeline automatically deploys to production (~2 minutes)

## 🚀 Deployment

### Automatic Deployment

Deployments happen automatically when you merge to the `main` branch:

1. **Push Code** → Push to `main` branch
2. **Pipeline Triggered** → Azure DevOps runs the build pipeline
3. **Build & Test** → Docker image created and pushed to ACR
4. **Deploy** → Image deployed to Azure Container Apps
5. **Live** → App is live in ~2 minutes

### Manual Deployment (if needed)

Go to Azure DevOps > **Pipelines** > **Build and Deploy** > **Run pipeline**

### View Deployment Logs

```bash
# Stream logs from the running container
az containerapp logs show \
  --name ca-hse-newsletter \
  --resource-group rg-hse-newsletter \
  --follow
```

## 🔐 Security

### Automated Security Updates

Renovate automatically checks for security vulnerabilities and creates pull requests:

- **Critical Security Issues**: Auto-merged immediately
- **Patch Updates**: Auto-merged after testing
- **Minor/Major Updates**: Manual review required

### Environment Variables

Sensitive values (API keys, tokens) are stored in:
- **Local Development**: `.env.local` (never commit this)
- **Production**: Azure DevOps Variable Group `hse-newsletter-vars`

**Never commit secrets to Git.**

## 📊 Monitoring & Logs

### Azure Portal

View app health and logs:
https://portal.azure.com → Search "ca-hse-newsletter"

### View Recent Logs

```bash
az containerapp logs show \
  --name ca-hse-newsletter \
  --resource-group rg-hse-newsletter \
  --tail 100
```

### View Recent Deployments

```bash
az containerapp revision list \
  --name ca-hse-newsletter \
  --resource-group rg-hse-newsletter \
  --output table
```

## 🐛 Troubleshooting

### App Won't Start Locally

```bash
# Clear cache and reinstall dependencies
rm -r node_modules
pnpm install
pnpm dev
```

### Build Fails with Missing Dependencies

```bash
# Update pnpm lock file
pnpm install --frozen-lockfile=false
```

### Environment Variables Not Loading

- Ensure `.env.local` exists in the project root
- Restart the dev server: `Ctrl+C` and `pnpm dev`
- Check that variable names match exactly (case-sensitive)

### Login Issues

- Verify `NEXT_PUBLIC_MSAL_CLIENT_ID` is correct
- Check that your Azure AD user has access
- Clear browser cookies and try again

### Container Won't Deploy

Check logs:
```bash
az containerapp logs show --name ca-hse-newsletter --resource-group rg-hse-newsletter --follow
```

Common issues:
- Missing environment variables
- Docker build failure (check ACR)
- Resource quota exceeded (check Azure Portal)

## 📚 Documentation

- **[Azure DevOps Setup Guide](./docs/AZURE_DEVOPS_SETUP.md)** - DevOps infrastructure and pipelines
- **[Team Onboarding Guide](./docs/TEAM_ONBOARDING.md)** - Getting started as a new team member
- **[Azure DevOps Wiki](https://dev.azure.com/Meyn-Poland/HSE-Newsletter-Manager/_wiki)** - Central documentation hub

## 🔗 Important Links

| Resource | URL |
|----------|-----|
| **Live App** | https://ca-hse-newsletter.braveplant-83c6ba92.westeurope.azurecontainerapps.io |
| **Azure DevOps Project** | https://dev.azure.com/Meyn-Poland/HSE-Newsletter-Manager |
| **Pipelines** | https://dev.azure.com/Meyn-Poland/HSE-Newsletter-Manager/_build |
| **Git Repository** | https://dev.azure.com/Meyn-Poland/HSE-Newsletter-Manager/_git/HSE-Newsletter-Manager |
| **Wiki** | https://dev.azure.com/Meyn-Poland/HSE-Newsletter-Manager/_wiki |
| **Azure Portal** | https://portal.azure.com |
| **Container App** | https://portal.azure.com → Search "ca-hse-newsletter" |

## 👥 Team

- **Project Lead**: [Your Name]
- **DevOps Lead**: [Your Name]
- **Developers**: [Team Members]

## ❓ Getting Help

1. **Check the Wiki** - https://dev.azure.com/Meyn-Poland/HSE-Newsletter-Manager/_wiki
2. **Read Documentation** - Check `/docs` folder in the repo
3. **Ask the Team** - Reach out to your project lead or DevOps lead
4. **Check Logs** - Most issues are visible in container logs

## 📝 Contributing Guidelines

1. Create a feature branch from `main`
2. Make your changes and commit with clear messages
3. Push to Azure Repos and create a PR
4. Wait for code review (1 approval)
5. Merge to `main` (auto-deploys to production)

**Keep commits small and focused on one feature per commit.**

## 📄 License

[Add your license here]

---

**Last Updated**: May 29, 2026  
**Maintained By**: [Your Team Name]  
**Questions?** Contact your project lead or check the Wiki
