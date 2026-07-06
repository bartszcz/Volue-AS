# HSE Newsletter Manager - Team Onboarding Guide

## Quick Start for New Team Members

Welcome to the HSE Newsletter Manager project! This guide will help you get started.

### What is this project?

A web application that helps manage and distribute HSE (Health, Safety, Environment) newsletters. It connects to OneDrive to manage files and uses Microsoft login for authentication.

---

## I Just Need to View the App

**Live URL:** https://ca-hse-newsletter.braveplant-83c6ba92.westeurope.azurecontainerapps.io

1. Open the URL in your browser
2. Click "Sign in with Microsoft"
3. Use your company Microsoft account

---

## I Need to Make a Small Content Change

For small text changes, you can edit directly in Azure DevOps:

1. Go to https://dev.azure.com/Meyn-Poland/HSE-Newsletter-Manager
2. Click **Repos** in the left sidebar
3. Navigate to the file you want to edit
4. Click **Edit** (top right)
5. Make your changes
6. Click **Commit** (top right)
7. Add a commit message describing your change
8. Click **Commit**

The app will automatically redeploy in ~2 minutes.

---

## I Need to Make Code Changes

### Prerequisites

- Git installed on your computer
- Node.js 22+ installed
- Code editor (VS Code recommended)

### Setup

```bash
# Clone the repository
git clone https://dev.azure.com/Meyn-Poland/HSE-Newsletter-Manager/_git/HSE-Newsletter-Manager

# Navigate to project folder
cd HSE-Newsletter-Manager

# Install dependencies
npm install -g pnpm
pnpm install

# Create local environment file
cp .env.example .env.local
# Edit .env.local with your values
```

### Development

```bash
# Start development server
pnpm dev

# Open http://localhost:3000 in your browser
```

### Deploy Changes

```bash
# Stage your changes
git add .

# Commit with a descriptive message
git commit -m "Add: new feature description"

# Push to deploy
git push origin main
```

Changes will be live in ~2 minutes.

---

## I Need to Check if Something is Working

### Check Pipeline Status

1. Go to https://dev.azure.com/Meyn-Poland/HSE-Newsletter-Manager
2. Click **Pipelines** in the left sidebar
3. Look at the status icons:
   - Green checkmark = Working
   - Red X = Failed
   - Blue circle = Running

### Check Application Logs

1. Go to https://portal.azure.com
2. Search for "ca-hse-newsletter"
3. Click on the Container App
4. Click **Log stream** in the left menu

---

## Common Tasks

### "The app is showing an error"

1. Check if a recent deployment failed (Azure DevOps → Pipelines)
2. If yes, click on the failed run to see what went wrong
3. Fix the issue and push again

### "I need to update a configuration value"

1. Go to Azure DevOps → Pipelines → Library
2. Click on **hse-newsletter-vars**
3. Find and update the variable
4. Click Save
5. Re-run the Build and Deploy pipeline

### "Security update is available"

Renovate automatically creates Pull Requests for security updates.

1. Go to Azure DevOps → Repos → Pull Requests
2. Review the Renovate PR
3. If tests pass, click **Complete** to merge
4. The app will automatically redeploy

---

## Key Concepts Explained

### What is a Pipeline?
An automated process that builds and deploys the application. Think of it as a robot that takes your code changes and puts them on the live website.

### What is a Container?
A package that contains the application and everything it needs to run. It ensures the app runs the same way everywhere.

### What is Azure DevOps?
Microsoft's platform for managing code, tracking work, and automating deployments. It's where all our code and pipelines live.

### What is Renovate?
A tool that automatically checks for security updates in our dependencies (libraries we use) and creates updates for us.

---

## Getting Help

- **Application questions:** Ask the development team
- **Azure/Infrastructure questions:** Ask the DevOps team lead
- **Access issues:** Contact IT support
