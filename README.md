# Apple Token Audit for Intune

[![Tests](https://github.com/Atliso-Dev/apple-token-audit/actions/workflows/test.yml/badge.svg)](https://github.com/Atliso-Dev/apple-token-audit/actions/workflows/test.yml)

Read-only PowerShell script that lists the three Apple dates in Intune that expire every year: the Apple MDM push certificate, every ADE enrolment program token and every Apps and Books (VPP) token. For each one you get the expiry date, days left and the Apple ID behind it.

Two of these are an annoyance when they lapse. The push certificate is not. Renew it with a different Apple ID, or click "Create a Certificate" instead of "Renew" in Apple's portal, and every iPhone, iPad and Mac you manage has to re-enrol. This script tells you which date is next and who owns it, before the date arrives.

## What it does

- Reads the push certificate, ADE tokens and VPP tokens from Intune through Microsoft Graph, with your own account
- Shows expiry date, days left, status and the Apple ID behind each one, plus where to renew it
- Notes whether an expired push certificate is still inside Microsoft's 30-day grace period
- Flags personal Apple IDs (gmail.com, icloud.com, outlook.com and similar)
- Marks VPP tokens Intune reports as `expired`, `invalid` or `assignedToExternalMDM` as Invalid, whatever the date says
- Counts the Apple devices that depend on the push certificate (optional)
- Exports a CSV and exits 1 when anything needs renewing, so it can run on a schedule
- Changes nothing in your tenant and renews nothing. There is no WhatIf switch because nothing is written
- Logs to `%LOCALAPPDATA%\Atliso\AppleTokenAudit.log`

## Quick start

1. Install the Graph authentication module once:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
```

2. Download [`Atliso-AppleTokenAudit.ps1`](Atliso-AppleTokenAudit.ps1) and check the config at the top:

```powershell
# ===== CONFIG =====
$OutputPath        = Join-Path $env:USERPROFILE 'Desktop\Atliso-AppleTokens.csv'
$WarnDays          = 60     # flag anything that expires within this many days
$CriticalDays      = 14
$CountAppleDevices = $true  # count the Apple devices that depend on the push certificate
$LogPath           = Join-Path $env:LOCALAPPDATA 'Atliso\AppleTokenAudit.log'
# ==================
```

3. Run it and sign in when prompted:

```powershell
.\Atliso-AppleTokenAudit.ps1
```

MSPs can point it at a customer tenant:

```powershell
.\Atliso-AppleTokenAudit.ps1 -TenantId contoso.onmicrosoft.com
```

## Output

One CSV row per certificate or token:

`Type, Name, AppleId, Expires, DaysLeft, Status, RenewIn, Note`

| Status | Meaning |
|---|---|
| `Expired` | Past its expiry date. For the push certificate, the note says whether you are inside the 30-day grace period |
| `Critical` | Expires within `$CriticalDays` days |
| `Warning` | Expires within `$WarnDays` days |
| `Invalid` | VPP token Intune reports as expired, invalid or assigned to another MDM |
| `OK` | Valid for longer than `$WarnDays` days |
| `Unknown` | No expiry date reported |

Exit code 0 when everything is OK, Unknown or not configured. Exit 1 when anything is Expired, Critical, Warning or Invalid.

A tenant with no Apple setup prints `No Apple MDM push certificate configured` and exits 0.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- The `Microsoft.Graph.Authentication` module
- Delegated, read-only Graph permissions:
  - `DeviceManagementServiceConfig.Read.All` (push certificate, ADE tokens)
  - `DeviceManagementApps.Read.All` (VPP tokens)
  - `DeviceManagementManagedDevices.Read.All` (only when `$CountAppleDevices` is on)

ADE tokens are only on the Graph beta endpoint. If that call fails, the script says so and carries on with the rest.

## What it doesn't do

It doesn't renew anything. Apple's portal needs an interactive sign-in with the right Apple ID, which is the point. It also doesn't read Apple Business Manager, so a token that exists in ABM but was never uploaded to Intune won't show.

## Tests

Pester tests mock Microsoft Graph, so they run without a tenant:

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -SkipPublisherCheck
Invoke-Pester ./tests
```

CI runs them on Windows PowerShell 5.1 and PowerShell 7.

## Guide

What each date breaks, and how to renew each one without forcing a re-enrolment: [Apple MDM push certificate expired in Intune? Check all 3 Apple dates](https://atliso.com/blog/intune-apple-mdm-push-certificate-expired)

Want this checked every night instead of once a year? [Atliso Pro](https://atliso.com/pro?ref=apple-token-audit) checks the push certificate and every ADE and VPP token daily and flags anything inside 30 days. The first scan is free.

## License

MIT. See [LICENSE](LICENSE).
