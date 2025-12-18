<#
.SYNOPSIS
  Configure the permissions required by the "NotifyDefenderKPIs" Logic App:
  - Run Advanced Hunting via the Defender API endpoint https://api.security.microsoft.com/api/advancedhunting/run
  - Send the KPI email via Microsoft Graph /users/{senderMailbox}/sendMail

.DESCRIPTION
  This script aligns with the template behavior:
  - Defender Advanced Hunting calls are executed against the Defender API endpoint using the Logic App Managed Identity.
  - The Sentinel section uses the Graph hunting endpoint.

  What it does:
  - Sets the Az context to the specified subscription.
  - Looks up the Logic App workflow and extracts the system-assigned MI service principal.
  - Assigns Microsoft Graph application permissions needed by the workflow (idempotent)
  - Configures Exchange Online RBAC for Application Mail.Send scoped to the specified shared mailbox (idempotent).
  - Prints a concise summary at the end.

.REQUIREMENTS
  - Azure Cloud Shell (PowerShell) or local PowerShell with:
      * Az.Accounts / Az.Resources
      * Microsoft.Graph.Authentication / Microsoft.Graph.Applications
      * ExchangeOnlineManagement
  - You must be:
      * Tenant admin for Graph app role assignments (e.g. Global Admin / Privileged Role Admin).
      * Exchange Administrator in Entra ID and member of Organization Management in Exchange Online.

.EXAMPLE
  ./Assign-LogicAppPermissions.ps1 `
    -ResourceGroup "<RG-NAME>" `
    -WorkflowName "<LOGICAPP-NAME>" `
    -TenantId "<TENANT-ID>" `
    -SubscriptionId "<SUBSCRIPTION-ID>" `
    -SharedMailboxAlias "<SHARED-MAILBOX-ALIAS>"
#>


param(
  [Parameter(Mandatory = $true)] [string]$ResourceGroup,
  [Parameter(Mandatory = $true)] [string]$WorkflowName,
  [Parameter(Mandatory = $true)] [string]$TenantId,
  [Parameter(Mandatory = $true)] [string]$SubscriptionId,
  [Parameter(Mandatory = $true)] [string]$SharedMailboxAlias
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# 0) Ensure required modules (install only if missing)
# -----------------------------------------------------------------------------
$requiredModules = @(
  'Az.Accounts',
  'Az.Resources',
  'Microsoft.Graph.Authentication',
  'Microsoft.Graph.Applications',
  'ExchangeOnlineManagement'
)

foreach ($module in $requiredModules) {
  if (-not (Get-Module -ListAvailable -Name $module)) {
    Write-Host "Installing module: $module" -ForegroundColor Cyan
    Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber
  }
  Import-Module -Name $module -ErrorAction Stop
}

# -----------------------------------------------------------------------------
# 1) Set Az context to the right subscription
# -----------------------------------------------------------------------------
if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
  Connect-AzAccount -ErrorAction Stop | Out-Null
}

Write-Host "Setting Az context to subscription: $SubscriptionId"
Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null

$subscriptionId = $SubscriptionId

# -----------------------------------------------------------------------------
# 2) Well-known IDs / values
# -----------------------------------------------------------------------------
# Microsoft Graph
$GraphAppId = '00000003-0000-0000-c000-000000000000'
# ThreatHunting.Read.All appRoleId (Application) (commonly used well-known id)
$ThreatHunting_AppRoleId = 'dd98c7f5-2d42-42d3-a0e4-633161547251'

# Defender XDR API (resource)
$DefenderXdrResourceSpn = 'https://api.security.microsoft.com'
$AdvancedHuntingRoleValue = 'AdvancedHunting.Read.All'

# -----------------------------------------------------------------------------
# 3) Get the Logic App's managed identity (service principal objectId)
# -----------------------------------------------------------------------------
$wf = Get-AzResource -ResourceGroupName $ResourceGroup `
  -ResourceType 'Microsoft.Logic/workflows' `
  -Name $WorkflowName `
  -ExpandProperties

$MiObjectId = $wf.Identity.PrincipalId
if (-not $MiObjectId) { $MiObjectId = $wf.Properties.identity.principalId }

if (-not $MiObjectId) {
  throw "No system-assigned managed identity found on workflow '$WorkflowName' in RG '$ResourceGroup'. Enable it first."
}

Write-Host "Managed Identity (SP objectId): $MiObjectId"

# -----------------------------------------------------------------------------
# 4) Connect to Microsoft Graph (delegated) so we can grant app role assignments
# -----------------------------------------------------------------------------
$scopes = @('AppRoleAssignment.ReadWrite.All', 'Application.Read.All')
Write-Host "Connecting to Microsoft Graph on tenant: $TenantId"
Connect-MgGraph -TenantId $TenantId -Scopes $scopes -NoWelcome

# MI service principal + AppId (needed for Exchange Online New-ServicePrincipal)
$MiServicePrincipal = Get-MgServicePrincipal -ServicePrincipalId $MiObjectId
$MiAppId = $MiServicePrincipal.AppId
$MiDisplayName = $MiServicePrincipal.DisplayName

Write-Host "Managed Identity (AppId): $MiAppId"
Write-Host "Managed Identity (Display Name): $MiDisplayName"

# -----------------------------------------------------------------------------
# 5) Assign Defender XDR AdvancedHunting.Read.All (Application) (idempotent)
# -----------------------------------------------------------------------------
Write-Host "`n=== Assigning Defender XDR API permission: $AdvancedHuntingRoleValue ===" -ForegroundColor Cyan

$defenderSp = Get-MgServicePrincipal -All | Where-Object {
  $_.ServicePrincipalNames -contains $DefenderXdrResourceSpn
} | Select-Object -First 1

if (-not $defenderSp) {
  throw "Could not resolve Defender XDR API service principal (SPN: $DefenderXdrResourceSpn) in this tenant."
}

$advHuntRoleId = ($defenderSp.AppRoles | Where-Object {
  $_.Value -eq $AdvancedHuntingRoleValue -and $_.AllowedMemberTypes -contains 'Application'
} | Select-Object -ExpandProperty Id)

if (-not $advHuntRoleId) {
  throw "Could not find app role '$AdvancedHuntingRoleValue' on Defender XDR API service principal."
}

$existingAdv = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $MiObjectId -All |
  Where-Object { $_.ResourceId -eq $defenderSp.Id -and $_.AppRoleId -eq $advHuntRoleId }

if ($existingAdv) {
  Write-Host "$AdvancedHuntingRoleValue already assigned." -ForegroundColor Yellow
} else {
  New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $MiObjectId -BodyParameter @{
    principalId = $MiObjectId
    resourceId  = $defenderSp.Id
    appRoleId   = $advHuntRoleId
  } | Out-Null
  Write-Host "Assigned $AdvancedHuntingRoleValue to the Logic App managed identity." -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# 6) Assign Microsoft Graph ThreatHunting.Read.All (Application) (idempotent)
#     (needed for Graph /security/runHuntingQuery, e.g. Sentinel block)
# -----------------------------------------------------------------------------
Write-Host "`n=== Assigning Microsoft Graph permission: ThreatHunting.Read.All ===" -ForegroundColor Cyan

$graphSp = Get-MgServicePrincipal -Filter "appId eq '$GraphAppId'" -All | Select-Object -First 1
if (-not $graphSp) {
  throw "Could not resolve Microsoft Graph service principal in this tenant."
}

$existingGraph = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $MiObjectId -All |
  Where-Object { $_.ResourceId -eq $graphSp.Id -and $_.AppRoleId -eq $ThreatHunting_AppRoleId }

if ($existingGraph) {
  Write-Host "ThreatHunting.Read.All already assigned." -ForegroundColor Yellow
} else {
  New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $MiObjectId -BodyParameter @{
    principalId = $MiObjectId
    resourceId  = $graphSp.Id
    appRoleId   = $ThreatHunting_AppRoleId
  } | Out-Null
  Write-Host "Assigned ThreatHunting.Read.All to the Logic App managed identity." -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# 7) Exchange Online RBAC for Scoped Mail.Send
# -----------------------------------------------------------------------------
Write-Host "`n=== Configuring Exchange Online RBAC for Scoped Mail.Send ===" -ForegroundColor Cyan

Write-Host "Connecting to Exchange Online..."
Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop | Out-Null

$scopeName = "$($MiDisplayName)-SharedMailbox-Scope"
$scopeFilter = "Alias -eq '$SharedMailboxAlias'"

$existingScope = Get-ManagementScope -Identity $scopeName -ErrorAction SilentlyContinue
if ($existingScope) {
  Write-Host "Management Scope '$scopeName' already exists." -ForegroundColor Yellow
} else {
  Write-Host "Creating Management Scope for shared mailbox: $SharedMailboxAlias"
  New-ManagementScope -Name $scopeName -RecipientRestrictionFilter $scopeFilter -ErrorAction Stop | Out-Null
  Write-Host "Created Management Scope: $scopeName" -ForegroundColor Green
}

$existingServicePrincipal = Get-ServicePrincipal -Identity $MiObjectId -ErrorAction SilentlyContinue
if ($existingServicePrincipal) {
  Write-Host "Service Principal already exists in Exchange Online (ObjectId: $MiObjectId)." -ForegroundColor Yellow
} else {
  Write-Host "Creating Service Principal pointer in Exchange Online..."
  New-ServicePrincipal -AppId $MiAppId -ObjectId $MiObjectId -DisplayName $MiDisplayName -ErrorAction Stop | Out-Null
  Write-Host "Created Service Principal: $MiDisplayName" -ForegroundColor Green
}

$assignmentName = "$($MiDisplayName)-Mail.Send-$SharedMailboxAlias"
$existingAssignment = Get-ManagementRoleAssignment -Identity $assignmentName -ErrorAction SilentlyContinue
if ($existingAssignment) {
  Write-Host "Role assignment '$assignmentName' already exists." -ForegroundColor Yellow
} else {
  Write-Host "Creating scoped Mail.Send role assignment..."
  New-ManagementRoleAssignment `
    -Name $assignmentName `
    -Role "Application Mail.Send" `
    -App $MiObjectId `
    -CustomResourceScope $scopeName `
    -ErrorAction Stop | Out-Null
  Write-Host "Created Role Assignment: $assignmentName" -ForegroundColor Green
}

Write-Host "`nTesting Service Principal authorization..."
$testResult = Test-ServicePrincipalAuthorization -Identity $MiObjectId -Resource $SharedMailboxAlias -ErrorAction SilentlyContinue
if ($testResult) {
  Write-Host "Authorization test returned results; scoped Mail.Send appears configured." -ForegroundColor Green
} else {
  Write-Host "Authorization test returned no results (possible propagation delay or misconfig)." -ForegroundColor Yellow
}

Disconnect-ExchangeOnline -Confirm:$false | Out-Null

# -----------------------------------------------------------------------------
# 8) Summary
# -----------------------------------------------------------------------------
Write-Host "`n=== Configuration Summary ===" -ForegroundColor Cyan
Write-Host "✓ Defender XDR API: AdvancedHunting.Read.All assigned"
Write-Host "✓ Microsoft Graph: ThreatHunting.Read.All assigned"
Write-Host "✓ Exchange Online: scoped Application Mail.Send configured"
Write-Host ""
