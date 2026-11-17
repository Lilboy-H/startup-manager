param(
  [string]$Repo = 'startup-manager',
  [switch]$Public,
  [string]$Token = ''
)

$ErrorActionPreference = 'Stop'
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  [Net.ServicePointManager]::CheckCertificateRevocationList = $false
} catch {}

$root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$tokenFile = Join-Path $root 'token.txt'

function Get-Token {
  if ($Token -ne '') { return $Token.Trim() }
  if (Test-Path $tokenFile) {
    $t = (Get-Content -Raw -Encoding ASCII $tokenFile)
    if ($t) { $t = $t.Trim() }
    if ($t -ne '') { return $t }
  }
  Write-Host ''
  Write-Host 'No GitHub token found.' -ForegroundColor Yellow
  Write-Host 'Create one at https://github.com/settings/tokens  (scope: repo)'
  Write-Host 'Save it as token.txt next to this script, or paste it below.'
  $sec = Read-Host 'Paste token (hidden)' -AsSecureString
  if (-not $sec) { return '' }
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr).Trim() }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

$tk = Get-Token
if (-not $tk) { Write-Host 'No token, aborted.' -ForegroundColor Red; exit 1 }

$headers = @{ Authorization = "token $tk"; 'User-Agent' = 'ziqidong-guanjia'; Accept = 'application/vnd.github+json' }

Write-Host 'Checking token...'
try { $me = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers -TimeoutSec 40 }
catch {
  Write-Host ('Auth/network failed: ' + $_.Exception.Message) -ForegroundColor Red
  exit 1
}
$login = $me.login
Write-Host ('Logged in as: ' + $login) -ForegroundColor Cyan

$exists = $false
try { $null = Invoke-RestMethod -Uri ("https://api.github.com/repos/$login/$Repo") -Headers $headers -TimeoutSec 40; $exists = $true }
catch { $exists = $false }

if (-not $exists) {
  $isPrivate = -not $Public.IsPresent
  $body = @{
    name        = $Repo
    private     = $isPrivate
    description = 'Windows startup manager: control every autostart entry, auto-sync on app install/uninstall'
    has_issues  = $true
    has_wiki    = $false
  } | ConvertTo-Json
  Write-Host ("Creating repo " + $login + "/" + $Repo + " (private=" + $isPrivate + ") ...")
  try { $null = Invoke-RestMethod -Uri 'https://api.github.com/user/repos' -Method Post -Headers $headers -Body $body -ContentType 'application/json' -TimeoutSec 40 }
  catch { Write-Host ('Create repo failed: ' + $_.Exception.Message) -ForegroundColor Red; exit 1 }
} else {
  Write-Host ('Repo exists: ' + $login + '/' + $Repo + ' , pushing into it.')
}

Push-Location $root
try {
  git config http.schannelCheckRevoke false | Out-Null
  $remotes = @(git remote)
  if ($remotes -contains 'origin') { git remote remove origin | Out-Null }
  git remote add origin ("https://x-access-token:" + $tk + "@github.com/" + $login + "/" + $Repo + ".git") | Out-Null

  Write-Host 'Pushing to GitHub ...' -ForegroundColor Cyan
  git push -u origin main
  if ($LASTEXITCODE -ne 0) {
    git remote set-url origin ("https://github.com/" + $login + "/" + $Repo + ".git") | Out-Null
    throw ('git push failed, exit code ' + $LASTEXITCODE)
  }
  git remote set-url origin ("https://github.com/" + $login + "/" + $Repo + ".git") | Out-Null
  Write-Host ''
  Write-Host ('Done: https://github.com/' + $login + '/' + $Repo) -ForegroundColor Green
} finally {
  Pop-Location
}
