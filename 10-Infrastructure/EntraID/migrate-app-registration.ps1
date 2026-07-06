# ============================================================
# New-AppRegistrationFromManifest.ps1
#
# Creates an Entra ID app registration from an exported
# Microsoft Graph app manifest JSON file.
#
# USAGE:
#   .\New-AppRegistrationFromManifest.ps1 -ManifestPath ".\grafana-manifest.json"
#   .\New-AppRegistrationFromManifest.ps1 -ManifestPath ".\grafana-manifest.json" -SecretExpiryYears 1
#   .\New-AppRegistrationFromManifest.ps1 -ManifestPath ".\grafana-manifest.json" -DryRun
#
# HOW TO EXPORT A MANIFEST FROM SOURCE TENANT:
#   Azure Portal → App Registrations → [your app] → Manifest → Download
#   OR via Graph API:
#   GET https://graph.microsoft.com/v1.0/applications/<object-id>
#
# REQUIREMENTS:
#   Install-Module Microsoft.Graph -Scope CurrentUser
# ============================================================

#Requires -Modules Microsoft.Graph.Applications, Microsoft.Graph.Authentication

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(HelpMessage = "Path to the exported app manifest JSON file (omit to pick from current folder)")]
    [string] $ManifestPath,

    [Parameter(HelpMessage = "Override the display name from the manifest")]
    [string] $DisplayName,

    [Parameter(HelpMessage = "Number of years before the new client secret expires (default: 2)")]
    [ValidateRange(1, 10)]
    [int] $SecretExpiryYears = 2,

    [Parameter(HelpMessage = "Create a new client secret automatically (default: true)")]
    [bool] $CreateSecret = $true,

    [Parameter(HelpMessage = "Preview what would be created without making any changes")]
    [switch] $DryRun,

    [Parameter(HelpMessage = "Overwrite if an app with the same display name already exists")]
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------------------------------------
# Helper: pretty section headers
# -----------------------------------------------------------
function Write-Section($title) {
    Write-Host ""
    Write-Host "━━━ $title ━━━" -ForegroundColor Cyan
}

# -----------------------------------------------------------
# Pick manifest interactively if none was supplied
# -----------------------------------------------------------
if (-not $ManifestPath) {
    $manifestsDir = Join-Path $PSScriptRoot "manifests"
    $searchDir    = if (Test-Path $manifestsDir) { $manifestsDir } else { Get-Location }

    $jsonFiles = Get-ChildItem -Path $searchDir -Filter "*.json" -File |
                 Where-Object { $_.Name -notlike "*.output.json" } |
                 Sort-Object Name

    if ($jsonFiles.Count -eq 0) {
        throw "No JSON files found in '$searchDir'. Add manifest files there or specify -ManifestPath explicitly."
    }

    Write-Host ""
    Write-Host "JSON files found in $($searchDir):" -ForegroundColor Cyan
    for ($i = 0; $i -lt $jsonFiles.Count; $i++) {
        Write-Host "  [$($i + 1)] $($jsonFiles[$i].Name)"
    }
    Write-Host ""

    do {
        $choice = Read-Host "Select a file [1-$($jsonFiles.Count)]"
    } until ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $jsonFiles.Count)

    $ManifestPath = $jsonFiles[[int]$choice - 1].FullName
    Write-Host "Using: $ManifestPath" -ForegroundColor Green
}

if (-not (Test-Path $ManifestPath -PathType Leaf)) {
    throw "File not found: $ManifestPath"
}

# -----------------------------------------------------------
# STEP 1: Load and validate manifest
# -----------------------------------------------------------
Write-Section "Loading Manifest"

$manifest = Get-Content -Raw -Path $ManifestPath | ConvertFrom-Json

if (-not $manifest.displayName) {
    throw "Manifest is missing 'displayName'. Is this a valid Entra app manifest?"
}

# If -DisplayName was not passed, prompt to confirm or change
if (-not $DisplayName) {
    Write-Host ""
    Write-Host "  Display name from manifest: " -NoNewline -ForegroundColor Cyan
    Write-Host $manifest.displayName -ForegroundColor White
    $nameInput = Read-Host "  Press Enter to keep it, or type a new name"
    $DisplayName = if ($nameInput.Trim()) { $nameInput.Trim() } else { $manifest.displayName }
}

$appName = $DisplayName

if ($appName -ne $manifest.displayName) {
    Write-Host "Display name: '$($manifest.displayName)' → '$appName'" -ForegroundColor Yellow
}
Write-Host "Manifest loaded: '$appName'" -ForegroundColor Green
Write-Host "  Source App ID : $($manifest.appId)"
Write-Host "  Sign-in Audience: $($manifest.signInAudience)"

# -----------------------------------------------------------
# SAML detection
# -----------------------------------------------------------
$isSamlApp      = $false
$samlIndicators = @()

if ($manifest.applicationTemplateId) {
    $isSamlApp = $true
    $samlIndicators += "Gallery template ID: $($manifest.applicationTemplateId)"
}
if ($manifest.optionalClaims.saml2Token -and @($manifest.optionalClaims.saml2Token).Count -gt 0) {
    $isSamlApp = $true
    $samlIndicators += "saml2Token optional claims present: $((@($manifest.optionalClaims.saml2Token) | ForEach-Object { $_.name }) -join ', ')"
}
if ($manifest.samlMetadataUrl) {
    $isSamlApp = $true
    $samlIndicators += "SAML metadata URL: $($manifest.samlMetadataUrl)"
}

if ($isSamlApp) {
    Write-Host ""
    Write-Host "  !! SAML APPLICATION DETECTED !!" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Indicators:" -ForegroundColor Yellow
    foreach ($indicator in $samlIndicators) {
        Write-Host "    - $indicator" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  What this script WILL migrate:" -ForegroundColor Cyan
    Write-Host "    - App registration shell (display name, sign-in audience)"
    Write-Host "    - App roles"
    Write-Host "    - Redirect URIs (reply URLs)"
    Write-Host "    - Optional claims (including saml2Token)"
    Write-Host "    - API permissions"
    Write-Host "    - Identifier URIs"
    Write-Host ""
    Write-Host "  What CANNOT be migrated and requires manual setup:" -ForegroundColor Red
    Write-Host "    - SAML signing certificate (must generate and upload a new one)"
    Write-Host "    - Enterprise App SAML configuration (Entity ID, Sign-on URL, Relay State)"
    Write-Host "    - Attribute mappings / claims transformation rules"
    Write-Host "    - Gallery template association (app will be created as a custom app, not from the gallery)"
    if ($manifest.applicationTemplateId) {
        Write-Host "    - Re-create from gallery instead: Azure Portal → Enterprise Apps → New → search by template" -ForegroundColor Yellow
    }
    Write-Host ""

    $confirm = Read-Host "  Proceed anyway? The registration shell will still be useful as a starting point [y/N]"
    if ($confirm -notmatch '^[yY]$') {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }
}

# -----------------------------------------------------------
# STEP 2: Connect
# -----------------------------------------------------------
Write-Section "Connecting to Microsoft Graph"

if (-not $DryRun) {
    Connect-MgGraph -Scopes "Application.ReadWrite.All" -NoWelcome
}

$tenantId = (Get-MgContext).TenantId
$account  = (Get-MgContext).Account
Write-Host "Connected as : $account"
Write-Host "Target Tenant: $tenantId"

# -----------------------------------------------------------
# STEP 3: Check for existing app
# -----------------------------------------------------------
Write-Section "Checking for Existing Registration"

$existing = $null
if (-not $DryRun) {
    $existing = Get-MgApplication -Filter "displayName eq '$appName'" -ErrorAction SilentlyContinue
}

if ($existing -and -not $Force) {
    Write-Warning "'$appName' already exists (AppId: $($existing.AppId))."
    Write-Host "Use -Force to overwrite (will DELETE the existing registration first)." -ForegroundColor Yellow
    exit 1
}

if ($existing -and $Force) {
    Write-Warning "Force flag set — deleting existing '$appName' (ID: $($existing.Id))..."
    if (-not $DryRun) {
        Remove-MgApplication -ApplicationId $existing.Id
        Write-Host "Deleted." -ForegroundColor Yellow
    }
}

# -----------------------------------------------------------
# STEP 4: Build app registration params from manifest
# -----------------------------------------------------------
Write-Section "Building App Registration"

# -- Redirect URIs --
$webRedirectUris = @()
if ($manifest.web.redirectUris) {
    $webRedirectUris = @($manifest.web.redirectUris)
}

$spaRedirectUris = @()
if ($manifest.spa.redirectUris) {
    $spaRedirectUris = @($manifest.spa.redirectUris)
}

$publicRedirectUris = @()
if ($manifest.publicClient.redirectUris) {
    $publicRedirectUris = @($manifest.publicClient.redirectUris)
}

Write-Host "  Web redirect URIs    : $($webRedirectUris.Count)"
Write-Host "  SPA redirect URIs    : $($spaRedirectUris.Count)"
Write-Host "  Public redirect URIs : $($publicRedirectUris.Count)"

# -- App Roles --
$appRoles = @()
if ($manifest.appRoles) {
    foreach ($role in $manifest.appRoles) {
        $appRoles += @{
            Id                 = [Guid]::NewGuid().ToString()   # Must be new GUID in target tenant
            DisplayName        = $role.displayName
            Description        = $role.description
            Value              = $role.value
            AllowedMemberTypes = @($role.allowedMemberTypes)
            IsEnabled          = [bool]$role.isEnabled
        }
    }
}
Write-Host "  App roles            : $($appRoles.Count)"

# -- Required Resource Access (API permissions) --
$requiredResourceAccess = @()
if ($manifest.requiredResourceAccess) {
    foreach ($resource in $manifest.requiredResourceAccess) {
        $accessList = @()
        foreach ($access in $resource.resourceAccess) {
            $accessList += @{
                Id   = $access.id
                Type = $access.type
            }
        }
        $requiredResourceAccess += @{
            ResourceAppId  = $resource.resourceAppId
            ResourceAccess = $accessList
        }
    }
}
Write-Host "  API permission sets  : $($requiredResourceAccess.Count)"

# -- Identifier URIs (Application ID URI) --
$identifierUris = @()
if ($manifest.identifierUris) {
    $identifierUris = @($manifest.identifierUris)
}
Write-Host "  Identifier URIs      : $($identifierUris.Count)"

# -- Exposed API scopes, pre-authorized apps, token version --
$apiPermissionScopes = @()
$preAuthorizedApps   = @()
$tokenVersion        = $null
if ($manifest.api) {
    if ($manifest.api.oauth2PermissionScopes) {
        foreach ($scope in $manifest.api.oauth2PermissionScopes) {
            $apiPermissionScopes += @{
                Id                      = $scope.id   # Keep source GUID so pre-authorized clients still match
                AdminConsentDescription = $scope.adminConsentDescription
                AdminConsentDisplayName = $scope.adminConsentDisplayName
                IsEnabled               = [bool]$scope.isEnabled
                Type                    = $scope.type
                UserConsentDescription  = $scope.userConsentDescription
                UserConsentDisplayName  = $scope.userConsentDisplayName
                Value                   = $scope.value
            }
        }
    }
    if ($manifest.api.preAuthorizedApplications) {
        foreach ($paa in $manifest.api.preAuthorizedApplications) {
            $preAuthorizedApps += @{
                AppId                  = $paa.appId
                DelegatedPermissionIds = @($paa.delegatedPermissionIds)
            }
        }
    }
    if ($null -ne $manifest.api.requestedAccessTokenVersion) {
        $tokenVersion = [int]$manifest.api.requestedAccessTokenVersion
    }
}
Write-Host "  Exposed API scopes   : $($apiPermissionScopes.Count)"
Write-Host "  Pre-authorized apps  : $($preAuthorizedApps.Count)"
if ($null -ne $tokenVersion) { Write-Host "  Token version        : v$tokenVersion" }

# -- Group membership claims --
$groupMembershipClaims = $null
if ($manifest.groupMembershipClaims) {
    $groupMembershipClaims = $manifest.groupMembershipClaims
}

# -- Fallback public client --
$isFallbackPublicClient = $null
if ($null -ne $manifest.isFallbackPublicClient -and $manifest.isFallbackPublicClient -ne '') {
    $isFallbackPublicClient = [bool]$manifest.isFallbackPublicClient
}

# -- Info URLs (branding/support links) --
$infoBlock = $null
if ($manifest.info) {
    $infoBlock = @{}
    if ($manifest.info.marketingUrl)        { $infoBlock.MarketingUrl        = $manifest.info.marketingUrl }
    if ($manifest.info.privacyStatementUrl) { $infoBlock.PrivacyStatementUrl = $manifest.info.privacyStatementUrl }
    if ($manifest.info.supportUrl)          { $infoBlock.SupportUrl          = $manifest.info.supportUrl }
    if ($manifest.info.termsOfServiceUrl)   { $infoBlock.TermsOfServiceUrl   = $manifest.info.termsOfServiceUrl }
    if ($infoBlock.Count -eq 0)             { $infoBlock = $null }
}

# -- Tags --
$tags = @()
if ($manifest.tags) { $tags = @($manifest.tags) }

# -- Certificate credentials (metadata only — private keys are never exportable) --
$hasCertCredentials = $manifest.keyCredentials -and @($manifest.keyCredentials).Count -gt 0
if ($hasCertCredentials) {
    Write-Host "  Certificate creds    : $(@($manifest.keyCredentials).Count) (must be re-uploaded manually)" -ForegroundColor Yellow
}

# -- Optional claims --
# The Graph SDK requires IMicrosoftGraphOptionalClaims, not a plain PSCustomObject,
# so each claim token array must be rebuilt as typed hashtables.
$optionalClaims = $null
if ($manifest.optionalClaims) {
    function ConvertTo-OptionalClaimList($claims) {
        if (-not $claims) { return @() }
        @($claims | ForEach-Object {
            $c = @{ Name = $_.name; Essential = [bool]$_.essential }
            if ($_.source)                   { $c.Source = $_.source }
            if ($_.additionalProperties)     { $c.AdditionalProperties = @($_.additionalProperties) }
            $c
        })
    }
    $optionalClaims = @{
        AccessToken = ConvertTo-OptionalClaimList $manifest.optionalClaims.accessToken
        IdToken     = ConvertTo-OptionalClaimList $manifest.optionalClaims.idToken
        Saml2Token  = ConvertTo-OptionalClaimList $manifest.optionalClaims.saml2Token
    }
}

# -- Build final params --
$appParams = @{
    DisplayName            = $appName
    SignInAudience         = $manifest.signInAudience ?? "AzureADMyOrg"
    RequiredResourceAccess = $requiredResourceAccess
}

if ($appRoles.Count -gt 0) {
    $appParams.AppRoles = $appRoles
}

if ($optionalClaims) {
    $appParams.OptionalClaims = $optionalClaims
}

# Web platform
if ($webRedirectUris.Count -gt 0) {
    $appParams.Web = @{
        RedirectUris          = $webRedirectUris
        ImplicitGrantSettings = @{
            EnableAccessTokenIssuance = [bool]$manifest.web.implicitGrantSettings.enableAccessTokenIssuance
            EnableIdTokenIssuance     = [bool]$manifest.web.implicitGrantSettings.enableIdTokenIssuance
        }
    }
    if ($manifest.web.logoutUrl) {
        $appParams.Web.LogoutUrl = $manifest.web.logoutUrl
    }
}

# SPA platform
if ($spaRedirectUris.Count -gt 0) {
    $appParams.Spa = @{ RedirectUris = $spaRedirectUris }
}

# Public client platform
if ($publicRedirectUris.Count -gt 0) {
    $appParams.PublicClient = @{ RedirectUris = $publicRedirectUris }
}

# Notes / description
if ($manifest.notes) {
    $appParams.Notes = $manifest.notes
}

# Identifier URIs
if ($identifierUris.Count -gt 0) {
    $appParams.IdentifierUris = $identifierUris
}

# Api block — exposed scopes, pre-authorized clients, token version
$apiBlock = @{}
if ($apiPermissionScopes.Count -gt 0) { $apiBlock.Oauth2PermissionScopes    = $apiPermissionScopes }
if ($preAuthorizedApps.Count -gt 0)   { $apiBlock.PreAuthorizedApplications = $preAuthorizedApps }
if ($null -ne $tokenVersion)           { $apiBlock.RequestedAccessTokenVersion = $tokenVersion }
if ($apiBlock.Count -gt 0)            { $appParams.Api = $apiBlock }

# Group membership claims (SecurityGroup / All / ApplicationGroup / DirectoryRole)
if ($groupMembershipClaims) {
    $appParams.GroupMembershipClaims = $groupMembershipClaims
}

# Fallback public client
if ($null -ne $isFallbackPublicClient) {
    $appParams.IsFallbackPublicClient = $isFallbackPublicClient
}

# Branding / info URLs
if ($infoBlock) {
    $appParams.Info = $infoBlock
}

# Tags
if ($tags.Count -gt 0) {
    $appParams.Tags = $tags
}

# -----------------------------------------------------------
# STEP 5: Dry run preview
# -----------------------------------------------------------
if ($DryRun) {
    Write-Section "DRY RUN — No changes made"
    Write-Host "Would create app registration with these settings:" -ForegroundColor Yellow
    $appParams | ConvertTo-Json -Depth 10
    Write-Host ""
    Write-Host "Run without -DryRun to apply." -ForegroundColor Cyan
    exit 0
}

# -----------------------------------------------------------
# STEP 6: Create the app registration
# -----------------------------------------------------------
Write-Section "Creating App Registration"

$newApp = New-MgApplication @appParams

Write-Host "Created successfully!" -ForegroundColor Green
Write-Host "  Display Name  : $($newApp.DisplayName)"
Write-Host "  Application ID: $($newApp.AppId)"
Write-Host "  Object ID     : $($newApp.Id)"

# -----------------------------------------------------------
# STEP 6b: Create the Service Principal (Enterprise App)
# New-MgApplication does not create it automatically — without
# this step the app is invisible in the Enterprise Apps portal blade.
# -----------------------------------------------------------
Write-Section "Creating Enterprise App (Service Principal)"

# Carry over tags from the manifest and ensure the portal visibility tag is present
$spTags = @($tags) + "WindowsAzureActiveDirectoryIntegratedApp"
$spTags = @($spTags | Select-Object -Unique)

$newSp = New-MgServicePrincipal -AppId $newApp.AppId -Tags $spTags

Write-Host "Created successfully!" -ForegroundColor Green
Write-Host "  SP Object ID  : $($newSp.Id)"
Write-Host "  Portal link   : https://portal.azure.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Overview/objectId/$($newSp.Id)" -ForegroundColor Cyan

# -----------------------------------------------------------
# STEP 7: Create client secret (if requested)
# -----------------------------------------------------------
$secretText = $null

if ($CreateSecret) {
    Write-Section "Creating Client Secret"

    $secretParams = @{
        PasswordCredential = @{
            DisplayName = "Migrated secret"
            EndDateTime = (Get-Date).AddYears($SecretExpiryYears).ToUniversalTime().ToString("o")
        }
    }

    $secret     = Add-MgApplicationPassword -ApplicationId $newApp.Id @secretParams
    $secretText = $secret.SecretText

    Write-Host "Secret created (expires: $($secret.EndDateTime))" -ForegroundColor Green
    Write-Host ""
    Write-Host "  !! COPY THIS NOW — it will not be shown again !!" -ForegroundColor Red
    Write-Host "  Client Secret: $secretText" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Store in Azure Key Vault immediately." -ForegroundColor Red
}

# -----------------------------------------------------------
# STEP 7b: Fix Identifier URIs that reference the old client ID
# -----------------------------------------------------------
$fixedIdentifierUris = $identifierUris | ForEach-Object { $_ -replace [regex]::Escape($manifest.appId), $newApp.AppId }
$uriWasFixed = ($fixedIdentifierUris -join ',') -ne ($identifierUris -join ',')

if ($uriWasFixed) {
    Write-Section "Fixing Identifier URIs"
    for ($i = 0; $i -lt $identifierUris.Count; $i++) {
        if ($fixedIdentifierUris[$i] -ne $identifierUris[$i]) {
            Write-Host "  $($identifierUris[$i])" -ForegroundColor DarkGray
            Write-Host "  → $($fixedIdentifierUris[$i])" -ForegroundColor Green
        }
    }
    Update-MgApplication -ApplicationId $newApp.Id -IdentifierUris $fixedIdentifierUris
    Write-Host "Updated." -ForegroundColor Green
}

# -----------------------------------------------------------
# STEP 8: Output summary
# -----------------------------------------------------------
Write-Section "Summary"

$summary = [ordered]@{
    DisplayName          = $newApp.DisplayName
    TenantId             = $tenantId
    ClientId             = $newApp.AppId
    ObjectId             = $newApp.Id
    ServicePrincipalId   = $newSp.Id
    ClientSecret         = if ($secretText) { $secretText } else { "(not created)" }
    SecretExpires        = if ($secretText) { (Get-Date).AddYears($SecretExpiryYears).ToString("yyyy-MM-dd") } else { "N/A" }
    AppRoles             = ($newApp.AppRoles | ForEach-Object { "$($_.Value) ($($_.DisplayName))" }) -join ", "
    RedirectURIs         = $webRedirectUris + $spaRedirectUris + $publicRedirectUris
}

$summary | Format-List

# -----------------------------------------------------------
# STEP 9: SSO parameters for the admin
# -----------------------------------------------------------
Write-Section "SSO Configuration Parameters"

# Build the default scopes list: openid/profile/email plus any scopes this app exposes
$defaultScopes = @("openid", "profile", "email")
if ($apiPermissionScopes.Count -gt 0) {
    $defaultScopes += $apiPermissionScopes | ForEach-Object { "$($newApp.AppId)/$($_.Value)" }
}

$ssoParams = [ordered]@{
    # Identity provider endpoints
    Authority              = "https://login.microsoftonline.com/$tenantId/v2.0"
    MetadataUrl            = "https://login.microsoftonline.com/$tenantId/v2.0/.well-known/openid-configuration"
    AuthorizationEndpoint  = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/authorize"
    TokenEndpoint          = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
    JwksUri                = "https://login.microsoftonline.com/$tenantId/discovery/v2.0/keys"
    # Application identity
    TenantId               = $tenantId
    ClientId               = $newApp.AppId
    ClientSecret           = if ($secretText) { $secretText } else { "(not created)" }
    # Token behaviour
    TokenVersion           = if ($null -ne $tokenVersion) { "v$tokenVersion" } else { "v2 (default)" }
    GroupMembershipClaims  = if ($groupMembershipClaims)  { $groupMembershipClaims } else { "(none)" }
    # Application ID URI — used as the token audience when calling this app's API
    IdentifierUri          = if ($identifierUris.Count -gt 0) { $identifierUris -join ", " } else { "(none)" }
    # Redirect URIs registered on the app
    RedirectUris           = $webRedirectUris + $spaRedirectUris + $publicRedirectUris
    # Scopes (OIDC base + any scopes this app exposes)
    Scopes                 = $defaultScopes
    # Scopes this app exposes to other clients
    ExposedScopes          = if ($apiPermissionScopes.Count -gt 0) {
                                 ($apiPermissionScopes | ForEach-Object { $_.Value }) -join ", "
                             } else { "(none)" }
    # Clients already pre-authorized to call without user consent prompt
    PreAuthorizedClients   = if ($preAuthorizedApps.Count -gt 0) {
                                 ($preAuthorizedApps | ForEach-Object { $_.AppId }) -join ", "
                             } else { "(none)" }
}

Write-Host ""
foreach ($key in $ssoParams.Keys) {
    $val = $ssoParams[$key]
    if ($val -is [array]) {
        Write-Host ("  {0,-25}: {1}" -f $key, ($val -join ", ")) -ForegroundColor White
    } else {
        Write-Host ("  {0,-25}: {1}" -f $key, $val) -ForegroundColor White
    }
}
Write-Host ""

# Warn about items that need manual attention
$manualSteps = [System.Collections.Generic.List[string]]::new()
$manualSteps.Add("1. Save the client secret to Azure Key Vault")
$manualSteps.Add("2. Grant admin consent in the portal:`n     https://portal.azure.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Permissions/objectId/$($newSp.Id)")
if ($hasCertCredentials) {
    $manualSteps.Add("3. Upload a certificate credential — the source app used certificate authentication")
}
$manualSteps.Add("$(if ($hasCertCredentials) { 4 } else { 3 }). Assign users/groups to app roles if needed")
$manualSteps.Add("$(if ($hasCertCredentials) { 5 } else { 4 }). Share the SSO parameters above with the admin configuring the application")

# Save summary + SSO params to output folder
$outputData = [ordered]@{
    Summary      = $summary
    SsoParams    = $ssoParams
    ManualSteps  = $manualSteps
}
$runStamp    = Get-Date -Format "yyyy-MM-dd_HHmmss"
$safeAppName = $appName -replace '[\\/:*?"<>|]', '_'
$outputDir   = Join-Path $PSScriptRoot "output\migrate\${runStamp}_${safeAppName}"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$summaryPath = Join-Path $outputDir "$safeAppName.output.json"
$outputData | ConvertTo-Json -Depth 5 | Out-File -FilePath $summaryPath -Encoding utf8
Write-Host "Full output saved to: $summaryPath" -ForegroundColor Cyan

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
$step = 1
Write-Host "  $step. Save the client secret to Azure Key Vault" ; $step++
Write-Host "  $step. Grant admin consent in the portal:" ; $step++
Write-Host "     https://portal.azure.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Permissions/objectId/$($newSp.Id)"
if ($hasCertCredentials) {
    Write-Host "  $step. Upload a certificate credential — the source app used certificate authentication" -ForegroundColor Yellow ; $step++
}
if ($isSamlApp) {
    Write-Host ""
    Write-Host "  !! SAML — additional manual steps required !!" -ForegroundColor Red
    Write-Host "  $step. Generate and upload a new SAML signing certificate:" ; $step++
    Write-Host "     Portal → Enterprise Apps → $appName → Single sign-on → Certificates"
    Write-Host "  $step. Configure SAML SSO settings (Entity ID, Reply URL, Sign-on URL):" ; $step++
    Write-Host "     Portal → Enterprise Apps → $appName → Single sign-on → Basic SAML Configuration"
    Write-Host "  $step. Verify attribute mappings match the source (email, upn, acct etc.):" ; $step++
    Write-Host "     Portal → Enterprise Apps → $appName → Single sign-on → Attributes & Claims"
    if ($manifest.applicationTemplateId) {
        Write-Host ""
        Write-Host "  Note: source was a gallery app (template $($manifest.applicationTemplateId))." -ForegroundColor Yellow
        Write-Host "  If SAML config is complex, consider re-creating via:" -ForegroundColor Yellow
        Write-Host "  Portal → Enterprise Apps → New application → search gallery → configure SAML there." -ForegroundColor Yellow
    }
    Write-Host ""
}
Write-Host "  $step. Assign users/groups to app roles if needed" ; $step++
Write-Host "  $step. Share the SSO parameters above with the admin configuring the application"