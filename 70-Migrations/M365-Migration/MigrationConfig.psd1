#Requires -Version 5.1
<#
.SYNOPSIS
    Central configuration file for the M365 Migration script suite.
    Fill this in once — every script reads from here automatically.

.HOW TO USE
    1. Edit every value in this file that has a <<FILL IN>> placeholder.
    2. Save the file.
    3. Run any script without parameters — it will load this config automatically.
       Example:  .\1-Inventory\Get-MailboxInventory.ps1

    You can still override individual values on the command line if needed.
    Command-line parameters always take priority over this file.

.CREDENTIALS
    Passwords are NOT stored here. Each script will prompt for credentials
    interactively via Connect-ExchangeOnline / Connect-MgGraph / Connect-PnPOnline
    on first use, then cache the session for the duration of the run.

    If you want fully unattended / service-principal auth, see the
    "Service Principal" section at the bottom of this file.
#>

@{

    # ──────────────────────────────────────────────────────────────────────────
    # SOURCE TENANT  (SmartPulse — the tenant you are migrating FROM)
    # ──────────────────────────────────────────────────────────────────────────

    # The onmicrosoft.com domain of the source tenant
    # Example: 'balancingpoolcom.onmicrosoft.com'
    SourceTenantId             = 'fdb6c84a-61e0-487d-a48d-b704c6ea2fda'

    # UPN of the admin account used to connect to the source tenant
    # This account needs: Exchange Admin, SharePoint Admin, Global Reader (or Global Admin)
    SourceAdminUPN             = 'bartlomiej.szczesny@quorumdev.com'

    # Primary email domain of the source company
    SourceDomain               = 'quorumdev.com'

    # Short human-readable company name — used in display names, suffixes, and log labels
    # Example: 'SmartPulse'  →  shared mailbox "Billing" becomes "Billing SmartPulse"
    CompanySuffix              = 'QuorumDev'

    # SharePoint Admin Centre URL for the source tenant
    # Pattern: https://<tenant>-admin.sharepoint.com
    SourceSharePointAdminUrl   = 'https://quorumdev-admin.sharepoint.com'


    # ──────────────────────────────────────────────────────────────────────────
    # TARGET TENANT  (Volue — the tenant you are migrating INTO)
    # ──────────────────────────────────────────────────────────────────────────

    # The onmicrosoft.com domain of the target tenant
    TargetTenantId             = 'volue.onmicrosoft.com'

    # UPN of the admin account used to connect to the target tenant
    # This account needs: Exchange Admin, SharePoint Admin, Global Admin (for license assignment)
    TargetAdminUPN             = 'adm-bartlomiej@volue.onmicrosoft.com'

    # Primary email domain of the target company
    TargetDomain               = 'volue.com'

    # SharePoint Admin Centre URL for the target tenant
    TargetSharePointAdminUrl   = 'https://volue-admin.sharepoint.com'


    # ──────────────────────────────────────────────────────────────────────────
    # MAPPING FILE PATHS
    # All paths are relative to the MigrationData\ folder.
    # Change only if you rename the files.
    # ──────────────────────────────────────────────────────────────────────────

    UserMappingCsv             = '.\MigrationData\user_mapping_confirmed.csv'
    SharedMappingCsv           = '.\MigrationData\shared_mailbox_mapping.csv'
    DLMappingCsv               = '.\MigrationData\dl_mapping.csv'
    SharePointMappingCsv       = '.\MigrationData\sharepoint_mapping.csv'
    OneDriveMappingCsv         = '.\MigrationData\onedrive_mapping.csv'
    SkuMappingCsv              = '.\MigrationData\sku_mapping.csv'
    Code2BatchPath             = '.\MigrationData\code2_All.csv'
    LicenseInventoryCsv        = '.\MigrationData\licenses_by_user.csv'
    MailboxInventoryCsv        = '.\MigrationData\mailboxes.csv'
    MailboxPermissionsCsv      = '.\MigrationData\mailbox_permissions.csv'
    DLMembersCsv               = '.\MigrationData\distribution_group_members.csv'
    DLOwnersCsv                = '.\MigrationData\distribution_group_owners.csv'
    UnifiedGroupsCsv           = '.\MigrationData\unified_groups.csv'
    GroupMembersCsv            = '.\MigrationData\unified_group_members.csv'
    ChannelsCsv                = '.\MigrationData\teams_channels.csv'
    PrivateChannelMembersCsv   = '.\MigrationData\teams_private_channel_members.csv'
    RoomEquipmentMappingCsv    = '.\MigrationData\room_equipment_mapping.csv'
    GuestActionsCsv            = '.\MigrationData\m365group_guest_actions_required.csv'
    SourceStatsCsv             = '.\MigrationData\mailbox_statistics.csv'
    PermissionResultsCsv       = '.\MigrationData\permission_apply_results.csv'

    OutputPath                 = '.\MigrationData'
    LogDirectory               = '.\Logs'


    # ──────────────────────────────────────────────────────────────────────────
    # MIGRATION BEHAVIOUR
    # ──────────────────────────────────────────────────────────────────────────

    # How long (seconds) to wait after creating a mailbox before continuing
    # Exchange Online provisioning is asynchronous; 60s is safe for most tenants
    MailboxProvisioningWaitSeconds     = 60

    # How long (seconds) to wait for Teams provisioning after creating a Group
    TeamsProvisioningTimeoutSeconds    = 120

    # Minimum % of source item count that must exist in target (post-migration check)
    # Flag mailboxes below this threshold for review
    ItemCountThresholdPct              = 90

    # Maximum acceptable % storage difference between source and target SPO sites
    StorageDeltaThresholdPct           = 15

    # Maximum acceptable % member count difference for DLs and M365 Groups
    MemberDeltaThresholdPct            = 5

    # Days of inactivity before post-cutover cleanup removes forwarding
    RecentActivityDays                 = 7

    # Set to $true to keep a copy at source AND forward to target (safer cutover)
    # Set to $false to forward only (no copy kept at source)
    DeliverToMailboxAndForward         = $true

    # HR CSV column names — change if your HR export uses different headers
    HRCsvFirstNameColumn       = 'FirstName'
    HRCsvLastNameColumn        = 'LastName'
    HRCsvEmailColumn           = 'Email'

    # Path to Source HR CSV (used by New-UserMapping.ps1)
    SourceHRCsv                = '.\MigrationData\SourceUsers.csv'

    # Path to Target HR CSV (used by New-UserMapping.ps1)
    TargetHRCsv                = '.\MigrationData\TargetUsers.csv'


    # ──────────────────────────────────────────────────────────────────────────
    # SERVICE PRINCIPAL AUTH  (optional — for unattended / pipeline runs)
    # Leave all values empty ('') to use interactive browser login instead.
    # ──────────────────────────────────────────────────────────────────────────

    # To use service principal auth:
    #   1. Register an App in each tenant's Entra ID
    #   2. Grant it the required Graph / EXO / SPO application permissions
    #   3. Fill in the values below
    #   4. Store the client secret securely — DO NOT commit this file to source control

    # Source tenant service principal
    SourceClientId             = ''   # App (client) ID
    SourceClientSecret         = ''   # Client secret  (or leave blank to use cert)
    SourceCertificateThumbprint = ''  # Certificate thumbprint (alternative to secret)

    # Target tenant service principal
    TargetClientId             = ''   # App (client) ID
    TargetClientSecret         = ''   # Client secret
    TargetCertificateThumbprint = ''  # Certificate thumbprint

}
