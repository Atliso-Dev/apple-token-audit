<#PSScriptInfo
.VERSION 1.0.0
.GUID a912a0ea-50bc-4989-a8ef-6842df946786
.AUTHOR Atliso
.COMPANYNAME Atliso
.COPYRIGHT (c) 2026 Atliso. MIT License.
.TAGS Intune Apple APNs ADE VPP MDM Graph Audit ReadOnly
.LICENSEURI https://github.com/Atliso-Dev/apple-token-audit/blob/main/LICENSE
.PROJECTURI https://atliso.com/blog/intune-apple-mdm-push-certificate-expired
.REQUIREDMODULES Microsoft.Graph.Authentication
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES First release.
#>

<#
.SYNOPSIS
  Atliso Apple Token Audit. Read-only.
.DESCRIPTION
  Lists the Apple MDM push certificate, every ADE enrolment token and every Apps and Books (VPP)
  token in Intune, with expiry date, days left and the Apple ID behind each one. Exports a CSV.
  Changes nothing in your tenant, so there is no WhatIf switch.
  https://atliso.com/blog/intune-apple-mdm-push-certificate-expired
.PARAMETER TenantId
  Optional. A tenant ID or domain to sign in to, for MSPs running it against customer tenants.
.NOTES
  Requires Microsoft.Graph.Authentication.
  Scopes: DeviceManagementServiceConfig.Read.All, DeviceManagementApps.Read.All
          (+ DeviceManagementManagedDevices.Read.All when $CountAppleDevices is on)
  Exit 0 = nothing expired, invalid or inside $WarnDays. Exit 1 = something needs renewing.
#>
[CmdletBinding()]
param(
  [string]$TenantId
)

# ===== CONFIG =====
$OutputPath        = Join-Path $env:USERPROFILE 'Desktop\Atliso-AppleTokens.csv'
$WarnDays          = 60     # flag anything that expires within this many days
$CriticalDays      = 14
$CountAppleDevices = $true  # count the Apple devices that depend on the push certificate
$LogPath           = Join-Path $env:LOCALAPPDATA 'Atliso\AppleTokenAudit.log'
# ==================

$ErrorActionPreference = 'Stop'
$PersonalDomains = 'gmail.com','googlemail.com','icloud.com','me.com','mac.com','outlook.com','hotmail.com','live.com','yahoo.com'
$GraceDays = 30

function Write-Log([string]$Message) {
  try {
    $dir = Split-Path -Path $LogPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Add-Content -Path $LogPath -Value ("{0}  {1}" -f (Get-Date -Format s), $Message)
  } catch { }
}

# HTTP status from a Graph error. PowerShell 7 and Windows PowerShell 5.1 throw different exception shapes.
function Get-HttpStatus($ErrorRecord) {
  $ex = $ErrorRecord.Exception
  try { if ($ex.Response -and $ex.Response.StatusCode) { return [int]$ex.Response.StatusCode } } catch { }
  if ([string]$ex.Message -match '\b(404|429)\b') { return [int]$Matches[1] }
  return $null
}

function Invoke-Graph([string]$Uri) {
  for ($try = 1; $try -le 5; $try++) {
    try {
      return Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject
    } catch {
      $status = Get-HttpStatus $_
      if ($status -eq 404) { return $null }
      if ($status -eq 429 -and $try -lt 5) {
        $wait = 10
        try { $ra = $_.Exception.Response.Headers.RetryAfter.Delta; if ($ra) { $wait = [int][math]::Ceiling($ra.TotalSeconds) } } catch { }
        Write-Log "429 on $Uri, waiting $wait s"
        Start-Sleep -Seconds $wait
        continue
      }
      throw
    }
  }
}

function Get-GraphList([string]$Uri) {
  $items = New-Object System.Collections.Generic.List[object]
  while ($Uri) {
    $page = Invoke-Graph $Uri
    if (-not $page) { break }
    foreach ($v in @($page.value)) { if ($null -ne $v) { $items.Add($v) } }
    $Uri = $page.'@odata.nextLink'
  }
  return ,$items
}

# Graph returns 0001-01-01 for dates that were never set. Treat anything before 2000 as no date.
function ConvertTo-UtcDate($Value) {
  if (-not $Value) { return $null }
  if ($Value -is [datetime]) { $d = $Value.ToUniversalTime() }
  else { $d = ([datetimeoffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime }
  if ($d.Year -lt 2000) { return $null }
  return $d
}

$now  = (Get-Date).ToUniversalTime()
$rows = New-Object System.Collections.Generic.List[object]

function Add-Row {
  param($Type, $Name, $AppleId, $Expires, $RenewIn, [string[]]$Notes = @(), $ForceStatus)
  $days = $null
  if ($Expires) { $days = [int][math]::Ceiling(($Expires - $now).TotalDays) }
  if ($ForceStatus)                { $status = $ForceStatus }
  elseif ($null -eq $days)         { $status = 'Unknown'; $Notes += 'No expiry date reported.' }
  elseif ($Expires -lt $now)       { $status = 'Expired' }
  elseif ($days -le $CriticalDays) { $status = 'Critical' }
  elseif ($days -le $WarnDays)     { $status = 'Warning' }
  else                             { $status = 'OK' }

  if ($AppleId -and ([string]$AppleId -match '@([^@\s]+)$') -and ($PersonalDomains -contains $Matches[1].ToLower())) {
    if ($Type -eq 'Push certificate') {
      $Notes += "Personal Apple ID. You can't change it without re-enrolling every Apple device, so make sure someone can still sign in to it."
    } else {
      $Notes += 'Personal Apple ID. Move this token to an organisation Apple ID at the next renewal.'
    }
  }

  $expiresText = ''
  if ($Expires) { $expiresText = $Expires.ToString('yyyy-MM-dd') }
  $rows.Add([pscustomobject]@{
    Type     = $Type
    Name     = $Name
    AppleId  = $AppleId
    Expires  = $expiresText
    DaysLeft = $days
    Status   = $status
    RenewIn  = $RenewIn
    Note     = ($Notes -join ' ')
  })
}

Write-Log 'Run started'
$scopes = @('DeviceManagementServiceConfig.Read.All', 'DeviceManagementApps.Read.All')
if ($CountAppleDevices) { $scopes += 'DeviceManagementManagedDevices.Read.All' }
$connect = @{ Scopes = $scopes; NoWelcome = $true }
if ($TenantId) { $connect.TenantId = $TenantId }
Connect-MgGraph @connect

# 1. Apple MDM push certificate. A 404 means none is configured.
$push = Invoke-Graph 'https://graph.microsoft.com/v1.0/deviceManagement/applePushNotificationCertificate'
$pushExpires = $null
if ($push) { $pushExpires = ConvertTo-UtcDate $push.expirationDateTime }
if ($push -and $pushExpires) {
  $notes = @()
  if ($pushExpires -lt $now) {
    $daysPast = [int][math]::Floor(($now - $pushExpires).TotalDays)
    if ($daysPast -le $GraceDays) { $notes += "Inside Microsoft's 30-day grace period. Renew now with the same Apple ID." }
    else { $notes += 'Past the 30-day grace period. Try Renew with the same Apple ID before creating a new certificate.' }
  }
  Add-Row -Type 'Push certificate' -Name 'Apple MDM push certificate' -AppleId $push.appleIdentifier -Expires $pushExpires `
    -RenewIn 'Intune > Devices > Device onboarding > Enrollment > Apple > Apple MDM Push Certificate' -Notes $notes
} else {
  Write-Host 'No Apple MDM push certificate configured. Apple devices are not managed in this tenant.' -ForegroundColor DarkGray
}

# 2. ADE enrolment program tokens. Graph only has these on beta, so a failure here doesn't stop the run.
try {
  $ade = Get-GraphList 'https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings?$select=id,tokenName,appleIdentifier,tokenExpirationDateTime,tokenType'
  foreach ($t in $ade) {
    $name = $t.tokenName
    if (-not $name) { $name = 'Enrolment program token' }
    Add-Row -Type 'ADE token' -Name $name -AppleId $t.appleIdentifier -Expires (ConvertTo-UtcDate $t.tokenExpirationDateTime) `
      -RenewIn 'Apple Business Manager > Preferences > MDM server > Download Token, then Intune > Enrollment program tokens > Renew token'
  }
} catch {
  Write-Log "ADE read failed: $($_.Exception.Message)"
  Write-Host "Could not read ADE tokens (beta endpoint): $($_.Exception.Message)" -ForegroundColor Yellow
}

# 3. Apps and Books (VPP) tokens
$vpp = Get-GraphList 'https://graph.microsoft.com/v1.0/deviceAppManagement/vppTokens?$select=id,organizationName,appleId,expirationDateTime,state,lastSyncStatus'
foreach ($t in $vpp) {
  $name = 'Apps and Books token'
  if ($t.organizationName) { $name = "Apps and Books: $($t.organizationName)" }
  $force = $null; $notes = @()
  if (@('expired', 'invalid', 'assignedToExternalMDM') -contains [string]$t.state) {
    $force = 'Invalid'; $notes += "Intune reports state '$($t.state)'."
  }
  if ([string]$t.lastSyncStatus -eq 'failed') { $notes += 'Last sync with Apple failed.' }
  Add-Row -Type 'VPP token' -Name $name -AppleId $t.appleId -Expires (ConvertTo-UtcDate $t.expirationDateTime) `
    -RenewIn 'Apple Business Manager > Preferences > Payments and Billing > Apps and Books > Content Tokens, then Intune > Tenant administration > Connectors and tokens > Apple VPP tokens' `
    -Notes $notes -ForceStatus $force
}

# 4. Optional: how many Apple devices depend on the push certificate
$appleCount = $null
if ($CountAppleDevices -and $pushExpires) {
  try {
    $devices = Get-GraphList 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$select=id,operatingSystem'
    $appleCount = @($devices | Where-Object { @('iOS', 'iPadOS', 'macOS') -contains $_.operatingSystem }).Count
  } catch {
    Write-Log "Device count failed: $($_.Exception.Message)"
  }
}

# Output
if ($rows.Count -gt 0) {
  $outDir = Split-Path -Path $OutputPath -Parent
  if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
  $rows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
  $rows | Sort-Object @{ Expression = { if ($null -eq $_.DaysLeft) { [int]::MaxValue } else { $_.DaysLeft } } } |
    Format-Table Type, Name, AppleId, Expires, DaysLeft, Status -AutoSize | Out-Host
}

foreach ($r in $rows | Where-Object { $_.Note }) {
  Write-Host ("{0} ({1}): {2}" -f $r.Name, $r.Status, $r.Note) -ForegroundColor Yellow
}
if ($null -ne $appleCount) {
  Write-Host ("{0} Apple devices depend on the push certificate." -f $appleCount)
}

$bad = @($rows | Where-Object { @('Expired', 'Critical', 'Warning', 'Invalid') -contains $_.Status })
if ($rows.Count -gt 0) {
  Write-Host ("{0} items checked, {1} need attention. CSV: {2}" -f $rows.Count, $bad.Count, $OutputPath)
} else {
  Write-Host 'No Apple certificates or tokens found in Intune. Nothing to export.'
}
Write-Host 'Check these every night instead of once a year: https://atliso.com/pro?ref=apple-token-audit' -ForegroundColor Cyan
Write-Log ("Run finished: {0} items, {1} need attention" -f $rows.Count, $bad.Count)

if ($bad.Count -gt 0) { exit 1 } else { exit 0 }
