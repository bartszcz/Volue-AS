# HSE Newsletter Manager — User Guide

## Overview

The **HSE Newsletter Manager** is a web application for managing, scheduling, and distributing Health, Safety & Environment (HSE) safety bulletin newsletters. It integrates with Microsoft 365 (OneDrive) for document storage and uses Azure AD for authentication. A Power Automate flow automatically sends scheduled newsletters by email on weekdays at **7:00 AM CET**.

---

## User Roles

| Role | Can Do |
|------|--------|
| **Admin** | Upload, delete, reorder, manage schedule & skip days, all settings |
| **Editor** | Upload, delete, reorder, manage schedule & skip days |
| **Viewer** | View newsletters and schedule only — no modifications |

Roles are assigned by your IT administrator via Azure Active Directory.

---

## Getting Started

1. Open the application URL in your browser.
2. Click **Sign In** (top right) and authenticate with your Microsoft 365 account.
3. If you see a **"Demo mode"** badge, you are not logged in — syncing to OneDrive will not work.
4. Your role (Admin / Editor / Viewer) is applied automatically based on your Azure AD account.

---

## Interface Layout

```
┌─────────────────────────────────────────────────────────┐
│  HEADER: Logo | Stats | Language | Theme | Sync | Login │
├───────────────────────┬─────────────────────────────────┤
│  LEFT PANEL           │  RIGHT PANEL                    │
│  [ Upload dropzone ]  │  [ Message preview / editor ]   │
│                       │                                 │
│  Tabs:                │  Tabs:                          │
│  • Send Schedule      │  • Preview                      │
│  • Upload Queue       │  • Source (HTML)                │
│  • OneDrive Files     │                                 │
│  • Skip Days          │                                 │
└───────────────────────┴─────────────────────────────────┘
│  FOOTER: "Power Automate sends Mon–Fri at 7:00 AM CET"  │
└─────────────────────────────────────────────────────────┘
```

---

## Core Workflows

### Workflow 1 — Create and Schedule a New Newsletter

This is the primary workflow for publishing new content.

1. **Prepare your document** — Create a Word (.docx) file with your newsletter content. Use a clear filename (e.g., `April-Safety-Update.docx`) — the filename becomes the newsletter title.
2. **Upload the file** — Drag and drop your .docx file onto the upload area at the top of the left panel, or click **Browse files**.
3. **Review the preview** — Select your uploaded message in the **Upload Queue** tab. The right panel shows a rendered preview of how the email will look.
4. **Edit if needed** — Click the pencil icon to edit the title or HTML content directly.
5. **Set the order** — Drag messages up/down or use the arrow buttons to arrange them in the order they should be sent.
6. **Sync to OneDrive** — Click **Sync to OneDrive** (top right). Confirm the dialog. A progress bar shows the upload status.
7. **Verify the schedule** — Go to the **Send Schedule** tab to confirm which newsletter sends on which date.
8. **Mark any holidays** — Go to the **Skip Days** tab to block out days when newsletters should not be sent.

---

### Workflow 2 — Review the Send Schedule

1. Click the **Send Schedule** tab in the left panel.
2. The top of the tab shows **"Next to send"** — the newsletter going out on the next workday.
3. The calendar view shows upcoming workdays with colour coding:
   - **Blue** — today's newsletter
   - **Red** — skipped date (no newsletter sent)
   - **Dashed border** — gap day (no content assigned)
4. Click the **eye icon** on any date to preview that newsletter in the right panel.

---

### Workflow 3 — Re-edit an Existing Newsletter

1. Go to the **OneDrive Files** tab.
2. Browse the list of HTML files stored in the Safety Bulletin folder.
3. Click the **download/import icon** next to the file you want to reuse.
4. The file appears in your **Upload Queue** as a draft.
5. Edit the title or HTML content as needed.
6. When ready, sync to OneDrive to publish.

---

## Feature Reference

### Upload Queue

The Upload Queue is your local workspace before syncing to OneDrive.

| Action | How |
|--------|-----|
| Upload .docx | Drag & drop or click "Browse files" |
| Select a message | Click its title in the list |
| Edit title/content | Click the pencil icon |
| Preview rendered HTML | Click the eye icon |
| Reorder messages | Drag and drop, or use arrow buttons |
| Delete a message | Click the trash icon |

**Status badges:**
- **Draft** — not yet uploaded to OneDrive
- **Synced** — successfully uploaded to OneDrive
- **Queued** — waiting for the next sync

> Your queue is auto-saved in your browser. Clearing browser data will delete unsaved drafts.

---

### Sync to OneDrive

The sync operation replaces all existing files in the OneDrive Safety Bulletin folder with your current queue.

- Files are numbered automatically: `01-Title.html`, `02-Title.html`, etc.
- The numbering determines the send order.
- **This operation cannot be undone.** Prepare your full queue before syncing.

After syncing, the Power Automate flow picks up the files and sends them on the configured schedule.

---

### Send Schedule

Newsletters are sent on **workdays only (Monday–Friday)** cycling through in order:

- If you have 5 newsletters, they send as: 1 → 2 → 3 → 4 → 5 → 1 → 2 → ...
- Skipped dates are passed over without consuming a newsletter slot.
- The same newsletter sends on the next available workday after a skipped date.

The **Order Management** sub-view (within Send Schedule) lets you drag and reorder newsletters already in OneDrive, then click **Save Order** to apply.

---

### Skip Days

Use this to prevent newsletters from being sent on holidays or closure days.

1. Click a future date on the calendar to mark it as skipped (turns red).
2. Optionally add a note (e.g., "Bank Holiday", "Company Closure").
3. To remove a skipped date, click it again in the calendar or use the trash icon in the list.
4. Click **Save** to persist changes to OneDrive.

> Skipped dates do not remove a newsletter from the cycle — they just delay it.

---

### OneDrive Files (Catalog)

Browse all HTML files currently stored in the OneDrive Safety Bulletin folder.

| Column | Description |
|--------|-------------|
| Filename | File name including order number prefix |
| Size | File size in KB |
| Last Modified | Date/time of last change |
| Actions | Preview (eye icon), Import (download icon) |

Click **Refresh** to reload the list from OneDrive.

---

### Message Preview

The right panel has two tabs:

- **Preview** — renders the newsletter HTML exactly as recipients will see it in their email client.
- **Source** — shows the raw HTML code for inspection or copying.

Click the **expand icon** (top right of preview panel) for a fullscreen view.

---

## Language & Theme

| Control | Location | Options |
|---------|----------|---------|
| Language | Top right header | English / Polish |
| Theme | Top right header | Light / Dark (system preference respected automatically) |

Settings are saved in your browser.

---

## Tips & Common Pitfalls

- **Don't sync after every upload.** Prepare your full queue first, then sync once.
- **Browser storage holds drafts.** Don't clear browser data while you have unsaved messages.
- **Multiple editors:** There is no conflict resolution — last save wins. Coordinate with colleagues before making changes.
- **File naming:** Don't rename files manually. Let the app assign numbering automatically to avoid conflicts.
- **Skipped dates:** Set them before syncing a new batch so the schedule shows correctly.
- **Demo mode:** If the "Demo mode" badge is visible, sign in first — changes won't reach OneDrive.

---

## Glossary

| Term | Meaning |
|------|---------|
| Safety Bulletin | A scheduled HSE newsletter sent by email |
| Sync | Uploading all queued messages to OneDrive, replacing previous files |
| Skip Day | A workday excluded from the newsletter schedule |
| Power Automate | Microsoft automation service that sends emails from OneDrive content |
| Draft | A message in the local queue, not yet synced to OneDrive |
| Order prefix | The number at the start of a filename (01-, 02-) that determines send order |

---

*Power Automate sends newsletters Monday–Friday at 7:00 AM CET.*
