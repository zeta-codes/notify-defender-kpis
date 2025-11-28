<#
.SYNOPSIS
  Assign Microsoft Graph "ThreatHunting.Read.All" (Application) to a Logic App's
  system-assigned managed identity (MI) and give it Reader on the Logic App
  so it can call ARM (e.g., to read its own tags).

.DESCRIPTION
  - Optionally sets the Az context to the specified subscription.
  - Looks up the Logic App workflow and extracts the MI service principal objectId.
  - Resolves the Microsoft Graph service principal and its app role IDs.
  - Assigns "ThreatHunting.Read.All" to the MI (idempotent).
  - Assigns Azure RBAC "Reader" on the Logic App resource to the MI (idempotent).
  - Prints a concise summary at the end.

.REQUIREMENTS
  - Azure Cloud Shell (PowerShell) or local PowerShell with:
      * Az.Accounts / Az.Resources
      * Microsoft.Graph
  - You must be:
      * Tenant admin for the Graph app role assignment (e.g. Global Admin or PRA), and
      * Owner / User Access Administrator on the Logic App scope for the RBAC assignment.

.EXAMPLE
  ./assign-logicapp-mi-threathunting.ps1 -ResourceGroup "<RG-NAME>" -WorkflowName "<LOGICAPP-NAME>" -TenantId "<TENANT-ID>" -SubscriptionId "<SUBSCRIPTION-ID>"
#>

param(
  [Parameter(Mandatory = $true)] [string]$ResourceGroup,
  [Parameter(Mandatory = $true)] [string]$WorkflowName,
  [string]$TenantId,        # optional: force a tenant if you have access to multiple
  [string]$SubscriptionId   # optional: target subscription explicitly
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# 0) Ensure required modules (install only if missing)
# -----------------------------------------------------------------------------

# Az.Accounts
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
  Install-Module Az.Accounts -Scope CurrentUser -Force -AllowClobber
}
Import-Module Az.Accounts -ErrorAction Stop

# Az.Resources
if (-not (Get-Module -ListAvailable -Name Az.Resources)) {
  Install-Module Az.Resources -Scope CurrentUser -Force -AllowClobber
}
Import-Module Az.Resources -ErrorAction Stop

# Microsoft.Graph (core module, loads meta-module)
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
  Install-Module Microsoft.Graph -Scope CurrentUser -Force -AllowClobber
}
Import-Module Microsoft.Graph -ErrorAction Stop

# -----------------------------------------------------------------------------
# 1) Set Az context to the right subscription (if provided)
# -----------------------------------------------------------------------------

# Connect to Azure if needed (if already connected, this is basically a no-op)
if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
  Connect-AzAccount -ErrorAction Stop | Out-Null
}

if ($SubscriptionId) {
  Write-Host "Setting Az context to subscription: $SubscriptionId"
  Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
}

# Resolve the effective subscription ID (either provided or current context)
$subscriptionId = if ($SubscriptionId) { $SubscriptionId } else { (Get-AzContext).Subscription.Id }
Write-Host "Using subscription: $subscriptionId"

# -----------------------------------------------------------------------------
# 2) Well-known IDs
# -----------------------------------------------------------------------------

$GraphAppId = '00000003-0000-0000-c000-000000000000'
$ThreatHunting_AppRoleId = 'dd98c7f5-2d42-42d3-a0e4-633161547251'

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
# 4) Connect to Microsoft Graph with the right permissions
# -----------------------------------------------------------------------------

$scopes = @('AppRoleAssignment.ReadWrite.All', 'Application.Read.All')

if ($TenantId) {
  Write-Host "Connecting to Microsoft Graph on tenant: $TenantId"
  Connect-MgGraph -TenantId $TenantId -Scopes $scopes -NoWelcome
}
else {
  Write-Host "Connecting to Microsoft Graph on current tenant"
  Connect-MgGraph -Scopes $scopes -NoWelcome
}

# -----------------------------------------------------------------------------
# 5) Resolve the Microsoft Graph service principal in this tenant
# -----------------------------------------------------------------------------

$graphSp = Get-MgServicePrincipal -Filter "appId eq '$GraphAppId'" -All | Select-Object -First 1
if (-not $graphSp) {
  throw "Could not resolve Microsoft Graph service principal in this tenant."
}

$GraphSpId = $graphSp.Id
Write-Host "Graph Service Principal: $GraphSpId"

# -----------------------------------------------------------------------------
# 6) Assign ThreatHunting.Read.All (idempotent)
# -----------------------------------------------------------------------------

$existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $MiObjectId -All |
  Where-Object { $_.ResourceId -eq $GraphSpId -and $_.AppRoleId -eq $ThreatHunting_AppRoleId }

if ($existing) {
  Write-Host "ThreatHunting.Read.All already assigned. Nothing to do." -ForegroundColor Yellow
}
else {
  $body = @{
    principalId = $MiObjectId
    resourceId  = $GraphSpId
    appRoleId   = $ThreatHunting_AppRoleId
  }
  New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $MiObjectId -BodyParameter $body | Out-Null
  Write-Host "Assigned ThreatHunting.Read.All to the Logic App managed identity." -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# 7) Assign Azure RBAC Reader on the Logic App so it can query ARM (read tags)
# -----------------------------------------------------------------------------

$logicAppResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$WorkflowName"
Write-Host "Logic App ResourceId: $logicAppResourceId"

# Make sure we have the Reader role definition
$readerRole = Get-AzRoleDefinition -Name "Reader"

# Check if an assignment already exists on this scope for this MI
$existingReaderAssignment = Get-AzRoleAssignment `
  -ObjectId $MiObjectId `
  -Scope $logicAppResourceId `
  -RoleDefinitionName "Reader" `
  -ErrorAction SilentlyContinue

if ($existingReaderAssignment) {
  Write-Host "Reader role already assigned on Logic App scope. Nothing to do." -ForegroundColor Yellow
}
else {
  New-AzRoleAssignment -ObjectId $MiObjectId -Scope $logicAppResourceId -RoleDefinitionName "Reader" | Out-Null
  Write-Host "Assigned Reader role on Logic App to the managed identity (for ARM/tag access)." -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# 8) Summary / usage
# -----------------------------------------------------------------------------

Write-Host "`nUse these in your Logic App HTTP actions:" -ForegroundColor Cyan
Write-Host '  For Graph hunting queries:'
Write-Host '    "authentication": { "type": "ManagedServiceIdentity", "audience": "https://graph.microsoft.com" }'
Write-Host ''
Write-Host '  For ARM/tag lookup:'
Write-Host '    "authentication": { "type": "ManagedServiceIdentity", "audience": "https://management.azure.com/" }'
