M365 Migration Script Suite
============================
SmartPulse (smartpulse.io) → Volue (volue.com)

QUICK START
-----------
1. Open MigrationConfig.psd1 and fill in your tenant details (takes ~2 minutes).
2. Open M365_Migration_Runbook.docx for the full step-by-step guide.
3. Run scripts directly — no parameters needed:

       .\1-Inventory\Get-MailboxInventory.ps1

   You can still override any value on the command line:

       .\1-Inventory\Get-MailboxInventory.ps1 -SourceDomain 'other.io'

CONTENTS
--------
MigrationConfig.psd1        *** FILL THIS IN FIRST ***  Central config file
MigrationHelpers.psm1       Shared helper module
1-Inventory\                Phase 1: Source tenant inventory (7 scripts)
2-Mapping\                  Phase 2: Source-to-target mapping (6 scripts)
3-TargetPrep\               Phase 3: Create target objects (7 scripts)
4-Validation\               Phase 4: Pre/post migration validation (5 scripts)
5-Cutover\                  Phase 5: Cutover day operations (5 scripts)
MigrationData\              All script outputs (CSVs) are written here
Logs\                       All script logs are written here
M365_Migration_Runbook.docx Full step-by-step operator instructions

PREREQUISITES
-------------
PowerShell 5.1+
Modules (run once):
    Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force
    Install-Module Microsoft.Graph          -Scope CurrentUser -Force
    Install-Module PnP.PowerShell           -Scope CurrentUser -Force
    Install-Module ImportExcel              -Scope CurrentUser -Force

Admin access to both source and target M365 tenants.
Code2 and Sharegate migration tools (licensed separately).

TOTAL: 30 scripts | ~9,000 lines of PowerShell
