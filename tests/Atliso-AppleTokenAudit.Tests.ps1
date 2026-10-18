# Pester 5+. Graph is mocked, so these run anywhere without a tenant or the Graph module:
#   Invoke-Pester ./tests

BeforeAll {
  $script:Script = Join-Path $PSScriptRoot '..\Atliso-AppleTokenAudit.ps1'

  # Stand-ins so the mocks have something to replace when Microsoft.Graph.Authentication isn't installed.
  if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) { function global:Connect-MgGraph { param($Scopes, $TenantId, [switch]$NoWelcome) } }
  if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) { function global:Invoke-MgGraphRequest { param($Method, $Uri, $OutputType) } }

  $script:Iso = { param([double]$Days) (Get-Date).ToUniversalTime().AddDays($Days).ToString('o') }

  # Runs the script against a fake tenant. $Graph maps a URI fragment to a response, or to 404.
  function script:Invoke-Audit([System.Collections.IDictionary]$Graph) {
    $env:USERPROFILE  = Join-Path $TestDrive 'home'
    $env:LOCALAPPDATA = Join-Path $TestDrive 'appdata'
    $global:AtlisoTestGraph = $Graph
    Mock Connect-MgGraph { }
    Mock Invoke-MgGraphRequest {
      foreach ($key in $global:AtlisoTestGraph.Keys) {
        if ($Uri -like "*$key*") {
          $v = $global:AtlisoTestGraph[$key]
          if ($v -eq 404) { throw 'Response status code does not indicate success: 404 (Not Found).' }
          if ($v -is [scriptblock]) { return & $v $Uri }
          return $v
        }
      }
      return [pscustomobject]@{ value = @() }
    }
    $out = & $script:Script 6>&1 | Out-String
    $csvPath = Join-Path $env:USERPROFILE 'Desktop\Atliso-AppleTokens.csv'
    $rows = @()
    if (Test-Path $csvPath) { $rows = @(Import-Csv $csvPath) }
    [pscustomobject]@{ Exit = $LASTEXITCODE; Output = $out; Rows = $rows }
  }

  function script:Push($Days, $AppleId = 'mdm@contoso.com') {
    [pscustomobject]@{ id = 'apns'; appleIdentifier = $AppleId; expirationDateTime = (& $script:Iso $Days) }
  }
  function script:List([object[]]$Items) { [pscustomobject]@{ value = $Items } }
}

Describe 'Atliso-AppleTokenAudit' {

  AfterEach {
    Remove-Item (Join-Path $TestDrive 'home') -Recurse -Force -ErrorAction SilentlyContinue
  }

  It 'push certificate expired 10 days ago: Expired, inside the grace period, exit 1' {
    $r = Invoke-Audit @{ 'applePushNotificationCertificate' = (Push -10); 'managedDevices' = (List @()) }
    $row = $r.Rows | Where-Object Type -eq 'Push certificate'
    $row.Status | Should -Be 'Expired'
    $row.Note | Should -Match "Inside Microsoft's 30-day grace period"
    $r.Exit | Should -Be 1
  }

  It 'push certificate expired 45 days ago: past the grace period, try Renew first' {
    $r = Invoke-Audit @{ 'applePushNotificationCertificate' = (Push -45) }
    ($r.Rows | Where-Object Type -eq 'Push certificate').Note | Should -Match 'Past the 30-day grace period'
  }

  It 'ADE token inside 14 days: Critical' {
    $ade = [pscustomobject]@{ id = 'ade1'; tokenName = 'Contoso ABM'; appleIdentifier = 'abm@contoso.com'; tokenExpirationDateTime = (& $script:Iso 9.5) }
    $r = Invoke-Audit @{ 'applePushNotificationCertificate' = 404; 'depOnboardingSettings' = (List @($ade)) }
    $row = $r.Rows | Where-Object Type -eq 'ADE token'
    $row.Status | Should -Be 'Critical'
    $row.DaysLeft | Should -Be 10
    $r.Exit | Should -Be 1
  }

  It 'VPP token in state invalid with a future date: Invalid, whatever the date says' {
    $vpp = [pscustomobject]@{ id = 'vpp1'; organizationName = 'Contoso'; appleId = 'vpp@contoso.com'; expirationDateTime = (& $script:Iso 200); state = 'invalid'; lastSyncStatus = 'failed' }
    $r = Invoke-Audit @{ 'applePushNotificationCertificate' = 404; 'vppTokens' = (List @($vpp)) }
    $row = $r.Rows | Where-Object Type -eq 'VPP token'
    $row.Name | Should -Be 'Apps and Books: Contoso'
    $row.Status | Should -Be 'Invalid'
    $row.Note | Should -Match "state 'invalid'"
    $row.Note | Should -Match 'Last sync with Apple failed'
    $r.Exit | Should -Be 1
  }

  It 'personal Apple ID on the push certificate gets the re-enrol warning, on a token the move-it note' {
    $vpp = [pscustomobject]@{ id = 'vpp1'; organizationName = 'Contoso'; appleId = 'someone@iCloud.com'; expirationDateTime = (& $script:Iso 300); state = 'valid' }
    $r = Invoke-Audit @{ 'applePushNotificationCertificate' = (Push 300 'old.admin@gmail.com'); 'vppTokens' = (List @($vpp)); 'managedDevices' = (List @()) }
    ($r.Rows | Where-Object Type -eq 'Push certificate').Note | Should -Match "Personal Apple ID. You can't change it without re-enrolling"
    ($r.Rows | Where-Object Type -eq 'VPP token').Note | Should -Match 'Move this token to an organisation Apple ID'
    ($r.Rows | Where-Object Type -eq 'Push certificate').Status | Should -Be 'OK'
    $r.Exit | Should -Be 0
  }

  It 'no push certificate (404) and nothing else: says so, exports nothing, exit 0' {
    $r = Invoke-Audit @{ 'applePushNotificationCertificate' = 404 }
    $r.Output | Should -Match 'No Apple MDM push certificate configured'
    $r.Output | Should -Match 'No Apple certificates or tokens found'
    $r.Output | Should -Match 'atliso.com/pro\?ref=apple-token-audit'
    $r.Rows.Count | Should -Be 0
    $r.Exit | Should -Be 0
  }

  It '0001-01-01 date: Unknown, which does not fail the run' {
    $vpp = [pscustomobject]@{ id = 'vpp1'; organizationName = 'Contoso'; appleId = 'vpp@contoso.com'; expirationDateTime = '0001-01-01T00:00:00Z'; state = 'valid' }
    $r = Invoke-Audit @{ 'applePushNotificationCertificate' = 404; 'vppTokens' = (List @($vpp)) }
    $row = $r.Rows | Where-Object Type -eq 'VPP token'
    $row.Status | Should -Be 'Unknown'
    $row.Expires | Should -BeNullOrEmpty
    $r.Exit | Should -Be 0
  }

  It 'ADE beta endpoint failing does not stop the push certificate and VPP results' {
    $vpp = [pscustomobject]@{ id = 'vpp1'; organizationName = 'Contoso'; appleId = 'vpp@contoso.com'; expirationDateTime = (& $script:Iso 120); state = 'valid' }
    $r = Invoke-Audit @{
      'applePushNotificationCertificate' = (Push 200)
      'depOnboardingSettings' = { throw 'Response status code does not indicate success: 403 (Forbidden).' }
      'vppTokens' = (List @($vpp))
      'managedDevices' = (List @())
    }
    $r.Output | Should -Match 'Could not read ADE tokens'
    $r.Rows.Count | Should -Be 2
    $r.Exit | Should -Be 0
  }

  It 'follows @odata.nextLink and counts only Apple devices' {
    $page2 = 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$skiptoken=2'
    $r = Invoke-Audit ([ordered]@{
      'applePushNotificationCertificate' = (Push 200)
      'skiptoken=2' = (List @([pscustomobject]@{ id = 'd3'; operatingSystem = 'macOS' }, [pscustomobject]@{ id = 'd4'; operatingSystem = 'Windows' }))
      'managedDevices' = [pscustomobject]@{ value = @([pscustomobject]@{ id = 'd1'; operatingSystem = 'iOS' }, [pscustomobject]@{ id = 'd2'; operatingSystem = 'iPadOS' }); '@odata.nextLink' = $page2 }
    })
    $r.Output | Should -Match '3 Apple devices depend on the push certificate'
  }

  It 'token inside the warning window but outside critical: Warning, exit 1' {
    $ade = [pscustomobject]@{ id = 'ade1'; tokenName = 'Contoso ABM'; appleIdentifier = 'abm@contoso.com'; tokenExpirationDateTime = (& $script:Iso 40) }
    $r = Invoke-Audit @{ 'applePushNotificationCertificate' = 404; 'depOnboardingSettings' = (List @($ade)) }
    ($r.Rows | Where-Object Type -eq 'ADE token').Status | Should -Be 'Warning'
    $r.Exit | Should -Be 1
  }
}
