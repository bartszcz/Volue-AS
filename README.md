# Volue AS – Automation & Scripting Workspace

This repository contains the full workspace for infrastructure, automation, identity, endpoint, integration, and migration scripts used in the Volue AS environment.
It is organized as a monorepo to keep everything consistent, searchable, and predictable.

Root directory on local machine:
`C:\Users\bartlomiej.szczesny\OneDrive - Volue AS\Documents\Scripts`

---

## 1. Purpose

This repo consolidates automation work across:

- Azure & on-prem infrastructure (AD, Hyper-V, Azure)
- Entra ID & identity security (PIM, app registrations)
- Endpoint management (Intune, M365)
- Integration tooling (ClickUp)
- Git automation, on-demand jobs, and reporting
- Tenant-to-tenant and M365 migrations
- Local admin utilities and maintenance tools
- Internal apps

The goal: **one place for everything**, clean conventions, predictable structure.

---

## 2. Folder Structure

Top-level folders use a numbered scheme so the order stays stable. Only folders
that currently hold scripts are listed; add new category folders as work arrives.

```text
Scripts
├── 00-Admin
│   └── Env                     # shared modules (VolueAutomation.psm1)
├── 10-Infrastructure
│   ├── AD
│   ├── Azure
│   ├── EntraID                 # + manifests/, output/ (generated run artifacts)
│   └── HyperV
├── 20-Endpoint
│   ├── Intune                  # autopilot-migration, intune-migration, lenovo-dock-update-issue
│   └── M365
├── 30-Identity-Security
│   └── PIM
├── 40-Automation
│   ├── Git
│   ├── OnDemand
│   └── Reporting
├── 50-Integrations
│   └── ClickUp                 # DocsSetup, VolueSetup
├── 60-Utility
│   └── OS-Maintenance
├── 70-Migrations
│   ├── 01-mx-migration
│   ├── 02-dg-migraions
│   ├── 03-spo-migrations
│   ├── 04-od-migration
│   ├── M365-Migration          # phased: 1-Inventory … 5-Cutover, + Logs
│   ├── Sharegate
│   └── Sharepoint-Teams
└── 80-Apps
    └── meyn-newsletter         # Next.js app
```

---

## 3. Conventions

- **Numbered top level** (`00`–`80`) keeps folder ordering deterministic; create
  a new `NN-Name` folder when a genuinely new category appears.
- **No empty placeholders.** Folders exist only when they contain scripts, so the
  tree always reflects real work. (Previous `.gitkeep` placeholders and reserved-
  but-empty category folders were removed.)
- **Generated output** (e.g. `10-Infrastructure/EntraID/output/`) is run-time
  artifacts, not source — it is not relied on for structure.
- Need an archive? Create `90-Legacy/` when you actually have something to retire.
