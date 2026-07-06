# ============================================================
# Export-SamlConfig.ps1
#
# Exports the IdP configuration an SSO admin needs to configure
# a SAML service provider to trust Microsoft Entra ID.
#
# USAGE:
#   .\Export-SamlConfig.ps1
#   .\Export-SamlConfig.ps1 -DisplayName "hub.smartuser.io (SAML)"
#
# OUTPUT:
#   - Console summary ready to paste into a handover email
#   - <AppName>.saml-config.json  — full config
#   - <AppName>.signing.cer       — IdP signing certificate (Base64 PEM)
#
# REQUIREMENTS:
#   Install-Module Microsoft.Graph -Scope CurrentUser
# ============================================================

#Requires -Modules Microsoft.Graph.Applications, Microsoft.Graph.Authentication

[CmdletBinding()]
param(
    [Parameter(HelpMessage = "Display name of the Enterprise App (omit to pick interactively)")]
    [string] $DisplayName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Section($title) {
    Write-Host ""
    Write-Host "━━━ $title ━━━" -ForegroundColor Cyan
}

# -----------------------------------------------------------
# Connect
# -----------------------------------------------------------
Write-Section "Connecting to Microsoft Graph"
Connect-MgGraph -Scopes "Application.Read.All" -NoWelcome

$tenantId = (Get-MgContext).TenantId
$account  = (Get-MgContext).Account
Write-Host "Connected as : $account"
Write-Host "Tenant       : $tenantId"

# -----------------------------------------------------------
# Find the Enterprise App (Service Principal)
# -----------------------------------------------------------
Write-Section "Finding Enterprise App"

if ($DisplayName) {
    $sp = Get-MgServicePrincipal -Filter "displayName eq '$DisplayName'" -ErrorAction SilentlyContinue
    if (-not $sp) { throw "No Enterprise App found with display name '$DisplayName'." }
} else {
    # List SAML apps interactively — preferredSingleSignOnMode eq 'saml'
    Write-Host "Loading SAML Enterprise Apps..." -ForegroundColor Yellow
    $samlApps = @(Get-MgServicePrincipal -All |
                  Where-Object { $_.PreferredSingleSignOnMode -eq "saml" } |
                  Sort-Object DisplayName)

    if ($samlApps.Count -eq 0) {
        throw "No SAML Enterprise Apps found in this tenant."
    }

    Write-Host ""
    Write-Host "SAML apps found:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $samlApps.Count; $i++) {
        Write-Host "  [$($i + 1)] $($samlApps[$i].DisplayName)"
    }
    Write-Host ""

    do {
        $choice = Read-Host "Select an app [1-$($samlApps.Count)]"
    } until ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $samlApps.Count)

    $sp = $samlApps[[int]$choice - 1]
}

Write-Host "Selected: $($sp.DisplayName)" -ForegroundColor Green
Write-Host "  App ID   : $($sp.AppId)"
Write-Host "  Object ID: $($sp.Id)"

# Re-fetch with explicit properties so KeyCredentials.Key bytes are populated
$sp  = Get-MgServicePrincipal -ServicePrincipalId $sp.Id `
           -Property "id,appId,displayName,keyCredentials,loginUrl,preferredSingleSignOnMode,samlSingleSignOnSettings"

# -----------------------------------------------------------
# Get the App Registration for SP-side config
# -----------------------------------------------------------
$app = Get-MgApplication -Filter "appId eq '$($sp.AppId)'" -ErrorAction SilentlyContinue

# -----------------------------------------------------------
# Extract signing certificate
# -----------------------------------------------------------
Write-Section "Extracting Signing Certificate"

$signingCert = @($sp.KeyCredentials) |
    Where-Object { $_.Usage -eq "Sign" -and $_.Type -eq "AsymmetricX509Cert" } |
    Sort-Object EndDateTime -Descending |
    Select-Object -First 1

$certThumbprint = $null
$certExpiry     = $null
$certPem        = $null

if ($signingCert -and $signingCert.Key) {
    try {
        $x509 = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([byte[]]$signingCert.Key)
        $certThumbprint = $x509.Thumbprint
        $certExpiry     = $x509.NotAfter.ToString("yyyy-MM-dd HH:mm UTC")
        $base64         = [Convert]::ToBase64String($signingCert.Key)
        $wrapped        = ($base64 -split "(?<=\G.{64})" | Where-Object { $_ }) -join "`n"
        $certPem        = "-----BEGIN CERTIFICATE-----`n$wrapped`n-----END CERTIFICATE-----"
        Write-Host "  Thumbprint : $certThumbprint" -ForegroundColor Green
        Write-Host "  Expires    : $certExpiry" -ForegroundColor Green
    } catch {
        Write-Host "  Found certificate metadata but could not parse key bytes: $_" -ForegroundColor Yellow
        $certThumbprint = $signingCert.CustomKeyIdentifier
        $certExpiry     = $signingCert.EndDateTime?.ToString("yyyy-MM-dd HH:mm UTC")
    }
} elseif ($signingCert) {
    # Key bytes not returned — use metadata only and note the cert path for manual download
    $certThumbprint = ([BitConverter]::ToString([byte[]]$signingCert.CustomKeyIdentifier) -replace '-', '')
    $certExpiry     = $signingCert.EndDateTime.ToString("yyyy-MM-dd HH:mm UTC")
    Write-Host "  Certificate found but key bytes unavailable via API." -ForegroundColor Yellow
    Write-Host "  Thumbprint : $certThumbprint" -ForegroundColor Yellow
    Write-Host "  Expires    : $certExpiry" -ForegroundColor Yellow
    Write-Host "  Download manually: Portal → Enterprise Apps → $($sp.DisplayName) → Single sign-on → Certificates → Download (Base64)" -ForegroundColor Yellow
} else {
    Write-Host "  No active signing certificate found." -ForegroundColor Yellow
}

# -----------------------------------------------------------
# Build IdP config
# -----------------------------------------------------------
Write-Section "Building IdP Configuration"

$samlConfig = [ordered]@{

    # --- What to send to the SSO admin ---

    IdPEntityId           = "https://sts.windows.net/$tenantId/"
    SsoUrl                = "https://login.microsoftonline.com/$tenantId/saml2"
    SloUrl                = "https://login.microsoftonline.com/$tenantId/saml2"
    FederationMetadataUrl = "https://login.microsoftonline.com/$tenantId/federationmetadata/2007-06/federationmetadata.xml?appid=$($sp.AppId)"
    SigningCertThumbprint = if ($certThumbprint) { $certThumbprint } else { "(none)" }
    SigningCertExpiry      = if ($certExpiry)     { $certExpiry }     else { "(none)" }

    # --- SP-side config in Entra (for reference) ---

    AppDisplayName        = $sp.DisplayName
    AppId                 = $sp.AppId
    TenantId              = $tenantId
    EntityId              = if ($app -and $app.IdentifierUris.Count -gt 0) { $app.IdentifierUris -join ", " } else { "(not set)" }
    ReplyUrls             = if ($app) { @($app.Web.RedirectUris) } else { @() }
    SignOnUrl             = if ($sp.LoginUrl) { $sp.LoginUrl } else { "(not set)" }
    RelayState            = if ($sp.SamlSingleSignOnSettings.RelayState) { $sp.SamlSingleSignOnSettings.RelayState } else { "(not set)" }

    # --- Attributes & Claims (read from optional claims) ---

    NameIdFormat          = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"
    NameIdSource          = "user.userprincipalname"
    Saml2TokenClaims      = if ($app -and $app.OptionalClaims.Saml2Token) {
                                ($app.OptionalClaims.Saml2Token | ForEach-Object { $_.Name }) -join ", "
                            } else { "(none configured)" }
}

# -----------------------------------------------------------
# Print handover summary
# -----------------------------------------------------------
Write-Section "SSO Admin Handover — $($sp.DisplayName)"

Write-Host ""
Write-Host "  Option 1 — Metadata import (recommended):" -ForegroundColor Green
Write-Host "  Give the admin the federation-metadata.xml file or this URL:" -ForegroundColor White
Write-Host "  $($samlConfig.FederationMetadataUrl)" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Option 2 — Manual fields (if SP does not support metadata import):" -ForegroundColor Cyan
Write-Host ""
Write-Host ("  {0,-30}: {1}" -f "IdP Entity ID",            $samlConfig.IdPEntityId)
Write-Host ("  {0,-30}: {1}" -f "SSO URL (Redirect)",       $samlConfig.SsoUrl)
Write-Host ("  {0,-30}: {1}" -f "SLO URL",                  $samlConfig.SloUrl)
Write-Host ("  {0,-30}: {1}" -f "Signing Cert Thumbprint",  $samlConfig.SigningCertThumbprint)
Write-Host ("  {0,-30}: {1}" -f "Signing Cert Expiry",      $samlConfig.SigningCertExpiry)
Write-Host ""
Write-Host "  Configured on the Entra side (for reference):" -ForegroundColor Cyan
Write-Host ""
Write-Host ("  {0,-30}: {1}" -f "SP Entity ID",             $samlConfig.EntityId)
Write-Host ("  {0,-30}: {1}" -f "Reply URL(s)",             ($samlConfig.ReplyUrls -join ", "))
Write-Host ("  {0,-30}: {1}" -f "Sign-on URL",              $samlConfig.SignOnUrl)
Write-Host ("  {0,-30}: {1}" -f "Relay State",              $samlConfig.RelayState)
Write-Host ("  {0,-30}: {1}" -f "NameID Format",            $samlConfig.NameIdFormat)
Write-Host ("  {0,-30}: {1}" -f "NameID Source",            $samlConfig.NameIdSource)
Write-Host ("  {0,-30}: {1}" -f "Extra SAML Token Claims",  $samlConfig.Saml2TokenClaims)
Write-Host ""

# -----------------------------------------------------------
# Save outputs
# -----------------------------------------------------------
Write-Section "Saving Output Files"

$safeName  = $sp.DisplayName -replace '[\\/:*?"<>|]', '_'
$runStamp  = Get-Date -Format "yyyy-MM-dd_HHmmss"
$outputDir = Join-Path $PSScriptRoot "output\saml-export\${runStamp}_${safeName}"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$outputBase = Join-Path $outputDir $safeName

# Download federation metadata XML
$metadataPath = "$outputBase.federation-metadata.xml"
try {
    Invoke-WebRequest -Uri $samlConfig.FederationMetadataUrl -OutFile $metadataPath -UseBasicParsing
    Write-Host "Metadata XML : $metadataPath" -ForegroundColor Green
    Write-Host "  -> Send this file to the SSO admin for direct import." -ForegroundColor Yellow
} catch {
    Write-Host "  Could not download metadata XML: $_" -ForegroundColor Yellow
    Write-Host "  Admin can fetch it directly from: $($samlConfig.FederationMetadataUrl)" -ForegroundColor Yellow
}

# JSON config (full reference)
$jsonPath = "$outputBase.saml-config.json"
$samlConfig | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding utf8
Write-Host "Config JSON  : $jsonPath" -ForegroundColor Green

# PEM certificate (fallback if SP needs cert uploaded separately)
if ($certPem) {
    $certPath = "$outputBase.signing.cer"
    $certPem | Out-File -FilePath $certPath -Encoding ascii
    Write-Host "Certificate  : $certPath" -ForegroundColor Green
    Write-Host "  -> Only needed if SP requires the cert uploaded separately instead of via metadata." -ForegroundColor Yellow
}
