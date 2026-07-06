# How It All Works — System Overview

This article explains how the HSE Newsletter Manager is built, deployed, and maintained. No deep technical knowledge required — think of it as a guided tour of the system.

---

## The Big Picture

The application lives in "the cloud" — specifically Microsoft Azure. When a developer makes a change to the code on their laptop, a chain of automated steps takes that change all the way to the live app. Here is that chain visualised:

```
Developer's laptop
      │
      │  git push (auto-push script)
      ▼
GitHub repository (bartszcz/scripts)
      │
      │  GitHub Action (automatic, detects code changes)
      ▼
Azure DevOps repository (Meyn-Poland/HSE-Newsletter-Manager)
      │
      │  Azure DevOps Pipeline (automatic, triggered by the push)
      ▼
Azure Container Registry  ◄── Docker image is built and stored here
      │
      │  Deploy step
      ▼
Azure Container Apps  ◄── The live application runs here
      │
      ▼
Users access the app in their browser
```

Each step below explains what is happening and why.

---

## Step 1 — The Code Lives in Two Places

### Why two repositories?

The developer works across multiple company tenants. The project runs under **Meyn Poland's** Azure DevOps organisation, but the developer's daily machine belongs to a different tenant. Pushing code directly between tenants adds authentication complexity.

The solution: use **GitHub** as a neutral middle ground that both sides can reach.

| Repository | Location | Purpose |
|---|---|---|
| `bartszcz/scripts` | GitHub | Developer's working copy (personal) |
| `Meyn-Poland/HSE-Newsletter-Manager` | Azure DevOps | The "official" copy that triggers builds |

### How does code get from GitHub to Azure DevOps?

A **GitHub Action** — a small automated script that runs on GitHub's servers — watches for any code change in the `60-Utility/Personal/` folder. When it detects one, it automatically copies just that folder's contents into the Azure DevOps repository.

> **Think of it like:** A courier that watches your outbox (GitHub) and delivers letters to the office (Azure DevOps) whenever something new appears.

---

## Step 2 — What is Git and Why Do We Push?

**Git** is version control software. It tracks every change ever made to the code — who changed what, when, and why. The code itself is stored in a **repository** (repo for short).

**Pushing** means sending your local changes to a remote server so others (and automated systems) can see them.

The `git-auto-push.ps1` script does this automatically: it runs on the developer's machine, detects any unsaved changes, creates a commit (a labelled snapshot of changes), and pushes it to GitHub.

---

## Step 3 — Azure DevOps Pipeline

Once the code arrives in Azure DevOps, a **pipeline** runs automatically.

### What is a pipeline?

A pipeline is a list of automated tasks that run one after another on a temporary cloud server. Think of it as a robot that follows a recipe:

1. Download the latest code
2. Build the application into a Docker image
3. Push the image to Azure Container Registry
4. Tell Azure Container Apps to start using the new image

The pipeline is defined in the file `azure-pipelines.yml` in the repository. Each line in that file is an instruction for the robot.

### How long does it take?

About **2 minutes** from code arriving in Azure DevOps to the new version being live.

---

## Step 4 — What is Docker?

**Docker** packages the application and everything it needs to run (Node.js, libraries, configuration) into a single file called an **image**. This image can be run identically on any computer or server — no "works on my machine" problems.

The image is built using a `Dockerfile` — a recipe that says: "Start with Node.js 24, copy these files, run these commands, expose this port."

> **Think of it like:** A shipping container. The goods inside (the app) are packed the same way every time. The container can be placed on any ship (any server) and the contents arrive intact.

### Azure Container Registry (ACR)

The built Docker images are stored here, like a library of versions. Every time a new build runs, a new image is stored with a unique build number. This makes it easy to roll back to a previous version if something goes wrong.

**Resource name:** `hsenewsletteracr`

---

## Step 5 — Azure Container Apps

This is where the application actually runs. Azure Container Apps is a Microsoft service that:
- Takes a Docker image from the registry
- Starts it as a running application
- Makes it accessible via a public URL
- Keeps it running 24/7
- Automatically restarts it if it crashes

**Resource name:** `ca-hse-newsletter`  
**Live URL:** https://ca-hse-newsletter.braveplant-83c6ba92.westeurope.azurecontainerapps.io

### Environment Variables

The app needs certain secret values to work (Azure AD credentials, OneDrive drive ID, etc.). These are stored in an Azure DevOps **Variable Group** called `hse-newsletter-vars` and injected into the Container App at deployment time. They are never stored in the code.

---

## Step 6 — Authentication (Azure AD + MSAL)

The app requires users to log in with their Microsoft 365 account. This is handled by:

- **Azure Active Directory (Azure AD)**: Microsoft's identity platform. The app is registered here as an "app registration" which gives it a unique Client ID.
- **MSAL (Microsoft Authentication Library)**: A library built into the app that handles the login flow, tokens, and session management.

When a user clicks "Sign In", MSAL redirects them to Microsoft's login page. After successful login, Microsoft sends a token back to the app that proves who the user is and what they're allowed to do.

**Roles** (Admin, Editor, Viewer) are assigned in Azure AD and included in the token automatically.

---

## Step 7 — OneDrive Integration

Newsletter HTML files and configuration are stored in a SharePoint/OneDrive folder. The app reads and writes these files using the **Microsoft Graph API** — Microsoft's unified API for all Microsoft 365 services.

The app uses the logged-in user's own access token to call Graph API, so it can only access files that the user has permission to access.

---

## Step 8 — Power Automate (the Email Sender)

**Power Automate** is Microsoft's workflow automation tool (formerly "Microsoft Flow"). A flow has been set up that:

1. Runs every weekday at **7:00 AM CET**
2. Reads the current position from `DocumentIndex.xlsx` in OneDrive
3. Lists the HTML newsletter files from the Safety Bulletin folder
4. Sends the current file as an email to `meyn_poland@meyn.com`
5. Increments the position counter for next time

The app does **not** send emails — Power Automate does. The app only manages which files are in OneDrive and in what order.

---

## Step 9 — Renovate (Automatic Security Updates)

**Renovate** is a bot that runs daily and scans all third-party libraries the app uses for known security vulnerabilities. When it finds an update:

- **Patch updates** (e.g. 1.0.1 → 1.0.2): merged automatically
- **Minor updates** (e.g. 1.0 → 1.1): merged automatically for dev tools
- **Major updates** (e.g. 1.x → 2.x): creates a PR for manual review

Renovate runs via its own pipeline (`renovate-pipeline.yml`) every day at 6 AM UTC.

---

## Putting It All Together — A Change Example

Here is what happens when a developer fixes a bug:

| Time | What happens |
|------|-------------|
| 9:00 AM | Developer edits a `.tsx` file on their laptop |
| 9:05 AM | Auto-push script detects the change, commits and pushes to GitHub |
| 9:05 AM | GitHub Action detects the change in `60-Utility/Personal/` |
| 9:06 AM | GitHub Action pushes the subtree to Azure DevOps repository |
| 9:06 AM | Azure DevOps Pipeline starts automatically |
| 9:07 AM | Docker image is built with the new code |
| 9:07 AM | Image is pushed to Azure Container Registry |
| 9:08 AM | Container App is updated to use the new image |
| 9:08 AM | Users see the fixed version in their browser |

Total time: **~3 minutes** from saving the file to live in production.

---

## Key Concepts Summary

| Term | Plain English |
|------|--------------|
| **Repository (repo)** | A folder of code with full history of every change |
| **Git push** | Sending local code changes to a remote server |
| **Pipeline** | An automated list of tasks that run on a cloud server |
| **Docker image** | A packaged, portable version of the application |
| **Container Registry** | A library that stores Docker images |
| **Container App** | A cloud service that runs a Docker image as a live application |
| **GitHub Action** | A script that runs automatically when code is pushed to GitHub |
| **Azure AD** | Microsoft's login and identity system |
| **MSAL** | The library that handles Microsoft login inside the app |
| **Graph API** | Microsoft's API for accessing OneDrive, SharePoint, etc. |
| **Power Automate** | Microsoft's tool for automating workflows (sends the emails) |
| **Renovate** | A bot that keeps dependencies up to date and secure |
| **Variable Group** | A secure store for secrets and configuration values |

---

## Useful Links

| Resource | URL |
|----------|-----|
| Live App | https://ca-hse-newsletter.braveplant-83c6ba92.westeurope.azurecontainerapps.io |
| Azure DevOps Project | https://dev.azure.com/Meyn-Poland/HSE-Newsletter-Manager |
| Pipelines | https://dev.azure.com/Meyn-Poland/HSE-Newsletter-Manager/_build |
| GitHub Repository | https://github.com/bartszcz |
| Azure Portal | https://portal.azure.com |
