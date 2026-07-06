#Requires -Modules Microsoft.Graph.Applications, Microsoft.Graph.Authentication, Microsoft.Graph.Groups, Microsoft.Graph.Users

<#
Purpose:
Create one or more Entra ID App Registrations from a config block at the top of this file.
Copy and adapt the Config section for each deployment — the Script section never needs to change.

Creates for each app:
- App Registration + Enterprise App (Service Principal)
- Redirect URIs (web)
- API permissions (resolved by permission name, not hardcoded GUID)
- App roles          (optional — leave $AppRoleDefs empty to skip)
- groups claim       (optional — controlled by $IncludeGroupsClaim)
- Client secret      (optional — controlled by $CreateClientSecret)
- Role assignments   (optional — leave $RoleAssignments empty to skip)

After this script:
- Store client secret(s) in Key Vault
- Grant admin consent for API permissions
- Enable "Assignment required" on the Enterprise App if you want to restrict access
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# Config — edit this section for each deployment
# ============================================================

$AppsToCreate = @(
    @{
        DisplayName = "airflow-1-swe-prod"
        RedirectUri = "https://airflow-1.swe-prod.internal.platform.volue.eu/auth/oauth-authorized/azure"
    },
    @{
        DisplayName = "airflow-2-swe-prod"
        RedirectUri = "https://airflow-2.swe-prod.internal.platform.volue.eu/auth/oauth-authorized/azure"
    }
)

# API permissions to request. Use the permission name (e.g. "User.Read"), not the GUID.
# Scopes = delegated (user context), Roles = application (daemon/service).
# Find names: Portal → App Registrations → API permissions → Add permission.
$RequiredPermissions = @(
    @{
        ResourceAppId = "00000003-0000-0000-c000-000000000000"  # Microsoft Graph
        Scopes        = @("User.Read")
        Roles         = @()
    }
)

# App roles to expose on the app. Leave empty @() if the app needs no custom roles.
$AppRoleDefs = @(
    @{ Value = "airflow_user";  DisplayName = "airflow_user";  Description = "Basic airflow user"; AllowedMemberTypes = @("User") },
    @{ Value = "airflow_admin"; DisplayName = "airflow_admin"; Description = "Airflow admin";       AllowedMemberTypes = @("User") }
)

# Which groups to include in the groups claim: "ApplicationGroup", "SecurityGroup", "All".
# Set to $null to omit groupMembershipClaims entirely.
$GroupMembershipClaims = "ApplicationGroup"

# Add the "groups" optional claim to access token, id token, and SAML token.
# Has no effect if $GroupMembershipClaims is $null.
$IncludeGroupsClaim = $true

# Create a client secret on each app. Set to $false to skip.
$CreateClientSecret   = $true
$SecretValidityMonths = 24

# Groups and users to assign to app roles on each Enterprise App.
# Leave empty @() to skip all assignments.
# Role must match a Value from $AppRoleDefs above.
# Note: "Default Access" cannot be assigned explicitly when custom app roles exist.
$RoleAssignments = @(
    @{ DisplayName = "All-Insight-Employees";  Type = "Group"; Role = "airflow_user"  },
    @{ DisplayName = "Gdańsk Insight";         Type = "Group"; Role = "airflow_user"  },
    @{ DisplayName = "Sirius Core Team";       Type = "Group"; Role = "airflow_admin" },
    @{ DisplayName = "Alwin Stockinger";       Type = "User";  Role = "airflow_user"  }
)

# Owners to add to both the App Registration and the Enterprise App.
# Use UPNs (e.g. "firstname.lastname@volue.com") — more reliable than display names.
# Leave empty @() to skip.
$Owners = @(
    "haris.sistek@volue.com",
    "havard.flo@volue.com",
    "rakshith.ponnappa@volue.com",
    "stig.alvestad@volue.com"
)

# ============================================================
# Script — do not edit below this line
# ============================================================

Connect-MgGraph -Scopes @(
    "Application.ReadWrite.All",
    "Directory.Read.All",
    "AppRoleAssignment.ReadWrite.All"
) -NoWelcome

Write-Host "Connected to Microsoft Graph." -ForegroundColor Green

# -----------------------------
# Resolve API permission GUIDs
# -----------------------------
# Done once here so the Graph lookup is not repeated for every app in the loop.

Write-Host ""
Write-Host "Resolving API permissions..." -ForegroundColor Cyan

$resolvedPermissions = @()
foreach ($perm in $RequiredPermissions) {
    $resourceSp = Get-MgServicePrincipal -Filter "appId eq '$($perm.ResourceAppId)'" -ErrorAction SilentlyContinue
    if (-not $resourceSp) {
        throw "Could not find Service Principal for resource AppId '$($perm.ResourceAppId)'."
    }

    $accessList = @()
    foreach ($scopeName in $perm.Scopes) {
        $scope = $resourceSp.Oauth2PermissionScopes | Where-Object { $_.Value -eq $scopeName -and $_.IsEnabled }
        if (-not $scope) { throw "Delegated scope '$scopeName' not found on '$($perm.ResourceAppId)'." }
        $accessList += @{ Id = $scope.Id; Type = "Scope" }
        Write-Host "  Delegated : $scopeName ($($scope.Id))" -ForegroundColor DarkGray
    }
    foreach ($roleName in $perm.Roles) {
        $role = $resourceSp.AppRoles | Where-Object { $_.Value -eq $roleName -and $_.IsEnabled }
        if (-not $role) { throw "Application role '$roleName' not found on '$($perm.ResourceAppId)'." }
        $accessList += @{ Id = $role.Id; Type = "Role" }
        Write-Host "  App role  : $roleName ($($role.Id))" -ForegroundColor DarkGray
    }

    if ($accessList.Count -gt 0) {
        $resolvedPermissions += @{ ResourceAppId = $perm.ResourceAppId; ResourceAccess = $accessList }
    }
}

# -----------------------------
# Results collection
# -----------------------------

$createdApps = @()

# -----------------------------
# Create App Registrations
# -----------------------------

foreach ($appConfig in $AppsToCreate) {

    $AppDisplayName = $appConfig.DisplayName
    $RedirectUri    = $appConfig.RedirectUri

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "Processing: $AppDisplayName" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    # Check if app already exists
    $escapedName  = $AppDisplayName.Replace("'", "''")
    $existingApps = @(Get-MgApplication -All -Filter "displayName eq '$escapedName'")

    if ($existingApps.Count -gt 0) {
        Write-Host "Already exists — skipping." -ForegroundColor Yellow
        $existingApps | Select-Object DisplayName, AppId, Id | Format-Table -AutoSize

        $createdApps += [pscustomobject]@{
            DisplayName         = $AppDisplayName
            ClientId            = $existingApps[0].AppId
            ApplicationObjectId = $existingApps[0].Id
            ServicePrincipalId  = $null
            SecretCreated       = $false
            Status              = "Skipped - already exists"
        }
        continue
    }

    # Build app roles (fresh GUIDs per app)
    $appRoles = @()
    foreach ($def in $AppRoleDefs) {
        $appRoles += @{
            Id                 = [guid]::NewGuid().ToString()
            Value              = $def.Value
            DisplayName        = $def.DisplayName
            Description        = $def.Description
            AllowedMemberTypes = @($def.AllowedMemberTypes)
            IsEnabled          = $true
        }
    }

    # Build $appParams
    $appParams = @{
        DisplayName            = $AppDisplayName
        SignInAudience         = "AzureADMyOrg"
        RequiredResourceAccess = $resolvedPermissions
    }

    if ($appRoles.Count -gt 0) {
        $appParams.AppRoles = $appRoles
    }

    if ($RedirectUri) {
        $appParams.Web = @{ RedirectUris = @($RedirectUri) }
    }

    if ($GroupMembershipClaims) {
        $appParams.GroupMembershipClaims = $GroupMembershipClaims
    }

    if ($IncludeGroupsClaim -and $GroupMembershipClaims) {
        $appParams.OptionalClaims = @{
            AccessToken = @(@{ Name = "groups"; Essential = $false })
            IdToken     = @(@{ Name = "groups"; Essential = $false })
            Saml2Token  = @(@{ Name = "groups"; Essential = $false })
        }
    }

    # Create App Registration
    $app = New-MgApplication -BodyParameter $appParams
    Write-Host "App Registration created." -ForegroundColor Green
    $app | Select-Object DisplayName, AppId, Id | Format-List

    # Create Service Principal (Enterprise App)
    # New-MgApplication does not create it automatically.
    # The WindowsAzureActiveDirectoryIntegratedApp tag makes it visible in the portal blade.
    $sp = New-MgServicePrincipal -AppId $app.AppId -Tags @("WindowsAzureActiveDirectoryIntegratedApp")
    Write-Host "Enterprise App created." -ForegroundColor Green
    Write-Host "  SP Object ID : $($sp.Id)"
    Write-Host "  Portal       : https://portal.azure.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Overview/objectId/$($sp.Id)" -ForegroundColor Cyan

    # Assign groups/users to app roles
    if ($RoleAssignments.Count -gt 0) {
        Write-Host ""
        Write-Host "Assigning roles..." -ForegroundColor Cyan

        # Build role value → ID map from the freshly created SP
        $spRoles   = @(Get-MgServicePrincipal -ServicePrincipalId $sp.Id -Property AppRoles).AppRoles
        $roleIdMap = @{ "Default Access" = [Guid]::Empty.ToString() }
        foreach ($r in $spRoles) { $roleIdMap[$r.Value] = $r.Id }

        foreach ($assignment in $RoleAssignments) {
            try {
                if ($assignment.Type -eq "Group") {
                    $principal = @(Get-MgGroup -Filter "displayName eq '$($assignment.DisplayName)'" -ErrorAction SilentlyContinue)
                } else {
                    $principal = @(Get-MgUser -Filter "displayName eq '$($assignment.DisplayName)'" `
                                    -ConsistencyLevel eventual -CountVariable c -ErrorAction SilentlyContinue)
                }

                if ($principal.Count -eq 0) {
                    Write-Host "  ⚠ Not found : $($assignment.Type) '$($assignment.DisplayName)' — skipping" -ForegroundColor Yellow
                    continue
                }

                $roleId = $roleIdMap[$assignment.Role]
                if (-not $roleId) {
                    if ($assignment.Role -eq "Default Access") {
                        Write-Host "  ⚠ Skipping 'Default Access' for $($assignment.DisplayName) — not assignable when custom app roles are defined" -ForegroundColor Yellow
                    } else {
                        Write-Host "  ⚠ Unknown role '$($assignment.Role)' for $($assignment.DisplayName) — skipping" -ForegroundColor Yellow
                    }
                    continue
                }

                New-MgServicePrincipalAppRoleAssignment `
                    -ServicePrincipalId $sp.Id `
                    -PrincipalId        $principal[0].Id `
                    -ResourceId         $sp.Id `
                    -AppRoleId          $roleId | Out-Null

                Write-Host "  ✓ $($assignment.DisplayName) ($($assignment.Type)) → $($assignment.Role)" -ForegroundColor Green
            } catch {
                Write-Host "  ✗ $($assignment.DisplayName): $_" -ForegroundColor Red
            }
        }
    }

    # Add owners to App Registration and Enterprise App
    if ($Owners.Count -gt 0) {
        Write-Host ""
        Write-Host "Adding owners..." -ForegroundColor Cyan

        foreach ($upn in $Owners) {
            try {
                $owner = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
                if (-not $owner) {
                    Write-Host "  ⚠ User not found: $upn — skipping" -ForegroundColor Yellow
                    continue
                }

                $ownerRef = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($owner.Id)" }
                New-MgApplicationOwnerByRef -ApplicationId $app.Id -BodyParameter $ownerRef
                New-MgServicePrincipalOwnerByRef -ServicePrincipalId $sp.Id -BodyParameter $ownerRef
                Write-Host "  ✓ $upn" -ForegroundColor Green
            } catch {
                Write-Host "  ✗ $upn : $_" -ForegroundColor Red
            }
        }
    }

    # Create client secret
    $secretCreated = $false
    $secretId      = $null
    $secretExpiry  = $null

    if ($CreateClientSecret) {
        $secret = Add-MgApplicationPassword `
            -ApplicationId $app.Id `
            -PasswordCredential @{
                DisplayName = "$AppDisplayName-secret"
                EndDateTime = (Get-Date).AddMonths($SecretValidityMonths)
            }

        $secretCreated = $true
        $secretId      = $secret.KeyId
        $secretExpiry  = $secret.EndDateTime

        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Yellow
        Write-Host "CLIENT SECRET — copy now, shown only once" -ForegroundColor Yellow
        Write-Host "Store in Key Vault. Do not paste into a ticket." -ForegroundColor Yellow
        Write-Host "============================================================" -ForegroundColor Yellow
        Write-Host "  App            : $AppDisplayName"
        Write-Host "  Client ID      : $($app.AppId)"
        Write-Host "  Secret ID      : $($secret.KeyId)"
        Write-Host "  Expires        : $($secret.EndDateTime)"
        Write-Host "  Secret value   : $($secret.SecretText)"
    }

    $createdApps += [pscustomobject]@{
        DisplayName         = $app.DisplayName
        ClientId            = $app.AppId
        ApplicationObjectId = $app.Id
        ServicePrincipalId  = $sp.Id
        SecretCreated       = $secretCreated
        SecretId            = $secretId
        SecretExpires       = $secretExpiry
        Status              = "Created"
    }
}

# -----------------------------
# Save results
# -----------------------------

$runStamp  = Get-Date -Format "yyyy-MM-dd_HHmmss"
$outputDir = Join-Path $PSScriptRoot "output\new-app-reg\$runStamp"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$outputPath = Join-Path $outputDir "results.json"
$createdApps | ConvertTo-Json -Depth 5 | Out-File -FilePath $outputPath -Encoding utf8
Write-Host ""
Write-Host "Results saved to: $outputPath" -ForegroundColor Cyan
Write-Host "  NOTE: Secret values are not saved here — copy them from the output above." -ForegroundColor DarkGray

# -----------------------------
# Final summary
# -----------------------------

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$createdApps | Format-Table DisplayName, ClientId, ApplicationObjectId, ServicePrincipalId, SecretCreated, SecretExpires, Status -AutoSize

Write-Host ""
Write-Host "Done." -ForegroundColor Green
