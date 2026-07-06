# Volue AS – Automation & Scripting Workspace

This repository contains the full workspace for infrastructure, automation, identity, endpoint, and integration scripts used in the Volue AS environment.  
It is organized as a monorepo to keep everything consistent, searchable, and future-proof.

Root directory on local machine:  
`C:\Users\bartlomiej.szczesny\OneDrive - Volue AS\Documents\Scripts`

---

## 1. Purpose

This repo consolidates all automation work across:

- Azure infrastructure (VMs, networking, storage, policy)
- Entra ID & identity security (PIM, Conditional Access, audit)
- Hyper-V cluster automation and migrations
- Endpoint management (Intune, M365, Defender)
- Integration tooling (ClickUp, Logic Apps, PowerAutomate, n8n)
- Reporting and scheduled jobs
- Local admin utilities and maintenance tools

The goal: **one place for everything**, clean conventions, predictable structure.

---

## 2. Folder Structure

```text
Scripts
├── 00-Admin
│   ├── Env
│   └── Templates
├── 10-Infrastructure
│   ├── AD
│   ├── EntraID
│   ├── Azure
│   ├── HyperV
│   ├── VMware
│   ├── Networking
│   ├── Storage
│   └── Backup
├── 20-Endpoint
│   ├── Intune
│   ├── M365
│   └── Defender
├── 30-Identity-Security
│   ├── PIM
│   ├── ConditionalAccess
│   └── Audit
├── 40-Automation
│   ├── Scheduled
│   ├── OnDemand
│   └── Reporting
├── 50-Integrations
│   ├── ClickUp
│   ├── PowerAutomate
│   ├── LogicApps
│   └── n8n
├── 60-Utility
│   ├── FileSystem
│   ├── OS-Maintenance
│   └── Personal
└── 90-Legacy
    ├── Archive-Pre2025
    └── ToRefactor
