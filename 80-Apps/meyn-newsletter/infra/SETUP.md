# HSE Newsletter Manager -- Complete Step-by-Step Setup Guide

This guide walks you through everything from zero to a working deployment. Follow each phase in order.

---

## PHASE 1: Get the Code onto Your Machine

### Step 1.1 -- Download the code from v0

1. In the v0 chat, click the **three dots** (top-right of the code block) and choose **"Download ZIP"**
2. Extract the ZIP to a folder on your computer, e.g. `C:\Projects\hse-newsletter-manager`

### Step 1.2 -- Install prerequisites on your computer

You need these installed (one-time setup):

| Tool | What it does | Download link |
|------|-------------|---------------|
| **Node.js 20+** | Runs JavaScript/TypeScript | https://nodejs.org (choose the LTS version) |
| **pnpm** | Package manager | Open a terminal and run: `npm install -g pnpm` |
| **Git** | Version control | https://git-scm.com/downloads |
| **Azure CLI** | Talks to Azure from terminal | https://learn.microsoft.com/en-us/cli/azure/install-azure-cli |

### Step 1.3 -- Verify everything works locally

Open a terminal in the project folder and run:

```bash
pnpm install
pnpm run dev
```

Open `http://localhost:3000` in your browser. You should see the HSE Newsletter Manager in **demo mode** (no login required yet, data saved locally). Test uploading a `.docx` file, reordering messages, and previewing HTML. If this works, the app itself is fine and we can proceed to set up Azure.

Press `Ctrl+C` in the terminal to stop the dev server when done.

---

## PHASE 2: Register the App in Azure AD (Entra ID)

This tells Microsoft's identity system that your app exists and is allowed to sign users in and access OneDrive.

### Step 2.1 -- Open the Azure Portal

1. Go to https://portal.azure.com
2. Sign in with your **work/organization account** (the one that has the M365/OneDrive subscription)

### Step 2.2 -- Navigate to App Registrations

1. In the top search bar, type **"App registrations"** and click it
2. Click **"+ New registration"** (blue button, top-left)

### Step 2.3 -- Fill in the registration form

| Field | What to enter |
|-------|---------------|
| **Name** | `HSE Newsletter Manager` |
| **Supported account types** | Select **"Accounts in this organizational directory only"** (Single tenant) |
| **Redirect URI** | Leave **blank for now** -- we will fill this in after we know our Azure URL (Step 4.5) |

3. Click **"Register"**

### Step 2.4 -- Copy the two IDs you will need

After registration, you land on the app's **Overview** page. Copy these two values and save them somewhere (e.g. a Notepad file). You will need them multiple times:

| Value on screen | Save it as | Example |
|----------------|------------|---------|
| **Application (client) ID** | `MSAL_CLIENT_ID` | `a1b2c3d4-e5f6-7890-abcd-1234567890ab` |
| **Directory (tenant) ID** | `MSAL_TENANT_ID` | `f1e2d3c4-b5a6-7890-abcd-0987654321fe` |

### Step 2.5 -- Add API permissions (allow the app to access OneDrive)

1. In the left sidebar, click **"API permissions"**
2. Click **"+ Add a permission"**
3. Choose **"Microsoft Graph"**
4. Choose **"Delegated permissions"** (NOT Application permissions)
5. Search for and check these two:
   - `User.Read` (should already be there by default)
   - `Files.ReadWrite.All`
6. Click **"Add permissions"**
7. **Important**: Click the button **"Grant admin consent for [Your Organization]"** (the blue button with a checkmark icon, near the top). If you don't see this button, ask your IT admin to do it. Without admin consent, users will get an error when signing in.

### Step 2.6 -- Add the SPA platform and enable token types

You must add a platform FIRST before you can enable token types.

1. In the left sidebar, click **"Authentication"**
2. Under **"Platform configurations"**, click **"+ Add a platform"**
3. In the panel that slides in, select **"Single-page application"** (SPA)
4. In the **Redirect URIs** field, enter: `http://localhost:3000`
5. Click **"Configure"**
6. The page reloads. You now see a **"Single-page application"** section
7. Scroll down to **"Implicit grant and hybrid flows"** (appears after adding the platform)
8. Check BOTH boxes:
   - [x] **Access tokens**
   - [x] **ID tokens**
9. Click **"Save"** at the top

> **Note**: We only add `http://localhost:3000` for now (local development).
> You will add your production Azure URL later in Step 4.5 after deploying.

---

## PHASE 3: Create Azure DevOps Project and Push Code

### Step 3.1 -- Create an Azure DevOps organization (skip if you already have one)

1. Go to https://dev.azure.com
2. Sign in with the same work account
3. If prompted, create a new organization (e.g. `yourcompany`) -- the free tier is enough

### Step 3.2 -- Create a new project

1. Click **"+ New project"** (top-right)
2. Fill in:
   - **Project name**: `HSE-Newsletter-Manager`
   - **Visibility**: Private
3. Click **"Create"**

### Step 3.3 -- Push your code to Azure DevOps Repos

1. In your new project, click **"Repos"** in the left sidebar
2. You will see a page with "Push an existing repository from command line". Copy the repository URL -- it looks like: `https://dev.azure.com/yourcompany/HSE-Newsletter-Manager/_git/HSE-Newsletter-Manager`
3. Open a terminal in your project folder and run these commands:

```bash
git init
git add .
git commit -m "Initial commit: HSE Newsletter Manager"

# IMPORTANT: git init creates a branch called "master" by default,
# but Azure DevOps expects "main". This renames it:
git branch -M main

git remote add origin https://dev.azure.com/yourcompany/HSE-Newsletter-Manager/_git/HSE-Newsletter-Manager
git push -u origin main
```

If prompted for credentials, use your Azure DevOps username and a Personal Access Token (PAT) as the password. You can create a PAT at: `https://dev.azure.com/yourcompany/_usersSettings/tokens`

4. Refresh the Azure DevOps Repos page -- you should see your code

---

## PHASE 4: Deploy Azure Infrastructure

### Step 4.1 -- Create the Azure Static Web App resource

**Option A: Using Azure CLI (recommended)**

Open a terminal and run each of these commands **one at a time**.

> **IMPORTANT for Windows/PowerShell users**: Each command below must be pasted as a
> single line. The commands are shown on one line each -- do NOT try to break them
> across multiple lines.

```bash
# 1. Log in to Azure (a browser window will open)
az login

# 2. Create a resource group (a folder for your Azure resources)
az group create --name rg-hse-newsletter --location westeurope

# 3. Deploy the infrastructure (REPLACE the three placeholder values below)
az deployment group create --resource-group rg-hse-newsletter --template-file infra/bicep/main.bicep --parameters appName=hse-newsletter-manager location=westeurope msalClientId=YOUR_MSAL_CLIENT_ID_HERE msalTenantId=YOUR_MSAL_TENANT_ID_HERE repositoryUrl=YOUR_AZURE_DEVOPS_REPO_URL_HERE
```

Replace the three placeholders:
- `YOUR_MSAL_CLIENT_ID_HERE` = the Application (client) ID from Step 2.4
- `YOUR_MSAL_TENANT_ID_HERE` = the Directory (tenant) ID from Step 2.4
- `YOUR_AZURE_DEVOPS_REPO_URL_HERE` = your Azure DevOps repo URL from Step 3, e.g. `https://dev.azure.com/yourcompany/HSE-Newsletter-Manager/_git/HSE-Newsletter-Manager`

**Option B: Using Azure Portal (if you prefer clicking)**

1. Go to https://portal.azure.com
2. Click **"+ Create a resource"**
3. Search for **"Static Web App"** and click it
4. Click **"Create"**
5. Fill in:
   - **Resource group**: Click "Create new" > name it `rg-hse-newsletter`
   - **Name**: `hse-newsletter-manager`
   - **Plan type**: Free
   - **Region**: West Europe (or wherever you are)
   - **Source**: **Other** (NOT Azure DevOps -- we deploy via pipeline instead)
6. Click **"Review + create"** then **"Create"**
7. After creation, go to the resource and click **"Configuration"** in the left sidebar
8. Add these application settings:
   - `NEXT_PUBLIC_MSAL_CLIENT_ID` = your client ID from Step 2.4
   - `NEXT_PUBLIC_MSAL_TENANT_ID` = your tenant ID from Step 2.4
   - `NEXT_PUBLIC_ONEDRIVE_FOLDER_PATH` = `/Safety bulletin`
9. Click **"Save"**

### Step 4.2 -- Get the deployment token

You need a token so that Azure DevOps can deploy to the Static Web App.

**If you used Option A (CLI):**

```bash
az staticwebapp secrets list --name hse-newsletter-manager --resource-group rg-hse-newsletter --query "properties.apiKey" -o tsv
```

Copy the output -- this is your `SWA_DEPLOYMENT_TOKEN`.

**If you used Option B (Portal):**

1. Go to your Static Web App resource in the portal
2. Click **"Manage deployment token"** in the top bar (Overview page)
3. Copy the token

### Step 4.3 -- Add environment variables to the Static Web App

**If you used Option A (CLI):** The Bicep template already set these. Verify with:

```bash
az staticwebapp appsettings list --name hse-newsletter-manager --resource-group rg-hse-newsletter
```

**If you used Option B (Portal):**

1. Go to your Static Web App in the portal
2. In the left sidebar, click **"Configuration"**
3. Under **"Application settings"**, add these three:

| Name | Value |
|------|-------|
| `NEXT_PUBLIC_MSAL_CLIENT_ID` | The Client ID from Step 2.4 |
| `NEXT_PUBLIC_MSAL_TENANT_ID` | The Tenant ID from Step 2.4 |
| `NEXT_PUBLIC_ONEDRIVE_FOLDER_PATH` | `/Safety bulletin` (or whatever your Power Automate flow uses) |

4. Click **"Save"**

### Step 4.4 -- Note your app URL

Your Static Web App has a URL like: `https://hse-newsletter-manager-xxxxxx.westeurope.azurestaticapps.net`

Find it on the **Overview** page of the Static Web App in the portal, or run:

```bash
az staticwebapp show --name hse-newsletter-manager --resource-group rg-hse-newsletter --query "defaultHostname" -o tsv
```

### Step 4.5 -- Go back and add the production Redirect URI

Now that you know your app's URL, go back and add it to Azure AD:

1. Go to https://portal.azure.com > **App registrations** > **HSE Newsletter Manager**
2. Click **"Authentication"** in the left sidebar
3. Under **"Platform configurations"**, you will see the **"Single-page application"** you created in Step 2.6 with `http://localhost:3000`
4. Click **"Add URI"** (next to the existing localhost URI)
5. Enter your production URL: `https://YOUR-APP-URL.azurestaticapps.net` (the URL from Step 4.4)
6. Click **"Save"** at the top

You should now have TWO redirect URIs listed under the SPA platform:
- `http://localhost:3000` (for local development)
- `https://your-app.azurestaticapps.net` (for production)

---

## PHASE 5: Set Up the Azure DevOps CI/CD Pipeline

### Step 5.1 -- Create a Variable Group

This stores your secrets so the pipeline can use them during build and deploy.

1. In Azure DevOps, go to your project
2. Click **"Pipelines"** > **"Library"** in the left sidebar
3. Click **"+ Variable group"**
4. Name it: `hse-newsletter-vars`
5. Add these variables:

| Name | Value | Keep secret? |
|------|-------|--------------|
| `NEXT_PUBLIC_MSAL_CLIENT_ID` | Your Client ID from Step 2.4 | No (it is public anyway) |
| `NEXT_PUBLIC_MSAL_TENANT_ID` | Your Tenant ID from Step 2.4 | No |
| `NEXT_PUBLIC_ONEDRIVE_FOLDER_PATH` | `/Safety bulletin` | No |
| `SWA_DEPLOYMENT_TOKEN` | The deployment token from Step 4.2 | **YES -- click the lock icon** |

6. Click **"Save"**

### Step 5.2 -- Create the Pipeline

1. Go to **"Pipelines"** > **"Pipelines"** in the left sidebar
2. Click **"Create Pipeline"** (or "New Pipeline")
3. Choose **"Azure Repos Git"** as the source
4. Select your **HSE-Newsletter-Manager** repository
5. Choose **"Existing Azure Pipelines YAML file"**
6. Set the path to: `/infra/azure-pipelines.yml`
7. Click **"Continue"**
8. Review the YAML (it should match what is in the repo)
9. Click **"Run"** to trigger the first build and deployment

### Step 5.3 -- Authorize the pipeline

On the first run, Azure DevOps may ask you to authorize:
- Access to the variable group: Click **"Permit"**
- Access to the environment: Click **"Permit"**

The pipeline will build the Next.js app and deploy it to your Static Web App. This takes about 3-5 minutes.

### Step 5.4 -- Verify the deployment

1. Go to your app URL from Step 4.4 in a browser
2. You should see the HSE Newsletter Manager with a **"Sign in with Microsoft"** button
3. Sign in with your work account
4. After signing in, you should see the full dashboard

---

## PHASE 6: Verify OneDrive Integration

### Step 6.1 -- Check the OneDrive folder

1. Go to https://onedrive.com and sign in with the same account
2. Navigate to the **Safety bulletin** folder (or whatever path your Power Automate flow uses)
3. This is the folder the app will push HTML files to

### Step 6.2 -- Do a test sync

1. In the HSE Newsletter Manager, upload a test `.docx` file
2. Give it a title and check the HTML preview looks good
3. Click **"Sync to OneDrive"**
4. Go back to OneDrive and verify the HTML file appeared with the correct numbered name (e.g. `01-Test-Document.html`)

### Step 6.3 -- Verify Power Automate still works

Your existing Power Automate flow ("HSE Messages") should continue to work unchanged. It lists files from the same OneDrive folder and sends them as emails on schedule. The only difference is that files are now managed by the frontend instead of manually.

---

## PHASE 7: Day-to-Day Usage (for the non-tech user)

Here is what the person managing newsletters needs to know:

### Uploading a new message

1. Open the app URL in a browser
2. Sign in with your Microsoft account (if not already signed in)
3. Drag a `.docx` file into the upload area (or click to browse)
4. The file is automatically converted to email-ready HTML
5. Give it a meaningful title (this becomes the filename)

### Reordering messages

- Drag messages up/down in the list to change the send order
- The numbers (01, 02, 03...) update automatically

### Editing a message

- Click the **eye icon** to preview what the email will look like
- Click the **pencil icon** to edit the HTML source (advanced)
- Click the **pencil icon** on the card to rename the title

### Pushing to OneDrive (making it live)

- When you are happy with the order and content, click **"Sync to OneDrive"**
- This replaces ALL files in the Safety bulletin folder with the current list
- Your Power Automate flow will then send them on its normal schedule (Mon-Fri 7am)

### Removing a message

- Click the **trash icon** on any message card to remove it from the queue
- It is not deleted from OneDrive until you click "Sync to OneDrive"

---

## Troubleshooting

### "Sign in" does nothing or shows an error

| Check | How to fix |
|-------|-----------|
| Client ID / Tenant ID wrong | Go to Azure Portal > App registrations > check the IDs match what is in your environment variables |
| Redirect URI missing | Go to App registrations > Authentication > ensure your app URL is listed as a SPA redirect URI |
| Admin consent not granted | Go to App registrations > API permissions > click "Grant admin consent" |
| Browser blocking popups | Allow popups for your app URL, or try the redirect login method |

### Files not appearing in OneDrive after sync

| Check | How to fix |
|-------|-----------|
| Wrong folder path | Verify `NEXT_PUBLIC_ONEDRIVE_FOLDER_PATH` matches the actual OneDrive folder |
| Missing permissions | Ensure `Files.ReadWrite.All` is granted with admin consent |
| The user does not own the folder | The app accesses OneDrive as the signed-in user. The OneDrive folder must belong to that user's OneDrive, not a SharePoint site |

### Power Automate not picking up new files

| Check | How to fix |
|-------|-----------|
| Flow is disabled | Go to Power Automate > check the "HSE Messages" flow is turned on |
| Folder path mismatch | The folder in Power Automate must be exactly the same as in the app |
| Counter file issue | Check the Excel file that tracks the index -- it may need resetting if you changed the number of files |

### Pipeline fails in Azure DevOps

| Check | How to fix |
|-------|-----------|
| Variable group not authorized | Click "Permit" when prompted on the pipeline run page |
| Deployment token expired | Get a new token (Step 4.2) and update it in the variable group |
| Build fails | Check the build logs -- usually a missing dependency. Run `pnpm install` locally and commit the updated lockfile |

---

## Architecture Diagram

```
[User's Browser]
      |
      | (1) Signs in via Azure AD / Entra ID
      v
[HSE Newsletter Manager]     -- hosted on Azure Static Web Apps
      |
      | (2) Uploads .docx, converts to HTML (client-side via mammoth.js)
      | (3) User reorders and edits messages
      | (4) "Sync to OneDrive" clicked
      v
[Microsoft Graph API]        -- uploads/deletes files
      |
      v
[OneDrive for Business]      -- /Safety bulletin/ folder
      |                         01-Message-Title.html
      |                         02-Another-Message.html
      |                         03-Third-Message.html
      v
[Power Automate Flow]        -- "HSE Messages" (unchanged)
      |                         Runs Mon-Fri at 7:00 AM
      |                         Picks next HTML file by index
      v
[Office 365 Outlook]         -- Sends the email to recipients
```

---

## Costs

| Resource | Cost |
|----------|------|
| Azure Static Web Apps (Free tier) | **Free** |
| Azure DevOps (up to 5 users) | **Free** |
| Azure AD App Registration | **Free** (included with M365) |
| Microsoft Graph API calls | **Free** (included with M365) |
| Power Automate (existing flow) | Whatever you are already paying |

**Total additional cost: $0/month** (on Free tier with under 5 users)
