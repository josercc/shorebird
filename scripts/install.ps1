# FlutterPatch CLI one-click install (Windows PowerShell).
#
# Installs the latest packaged CLI into ~/.flutterpatch.
# If that install already exists, exits without changing anything unless -Force.
# Flutter SDKs are installed later via `flutterpatch flutter install|use`.
#
# Usage:
#   iwr -UseBasicParsing https://<site>/downloads/install_cli.ps1 | iex
#   .\scripts\install.ps1              # skip if already installed
#   .\scripts\install.ps1 -Force       # reinstall / upgrade to latest CLI
#
# Environment:
#   FLUTTERPATCH_ROOT
#   FLUTTERPATCH_DOWNLOADS_ENDPOINT
#   FLUTTERPATCH_DOWNLOADS_PROJECT_ID
#   FLUTTERPATCH_CLI_URL

[CmdletBinding()]
param(
  [switch]$Force,
  [string]$Url = ""
)

$ErrorActionPreference = "Stop"

$DefaultDownloadsEndpoint = if ($env:FLUTTERPATCH_DEFAULT_DOWNLOADS_ENDPOINT) {
  $env:FLUTTERPATCH_DEFAULT_DOWNLOADS_ENDPOINT
} else {
  "http://139.199.88.243:8080/v1/functions/meta_ota_website_downloads/executions"
}
$DefaultDownloadsProject = if ($env:FLUTTERPATCH_DEFAULT_DOWNLOADS_PROJECT_ID) {
  $env:FLUTTERPATCH_DEFAULT_DOWNLOADS_PROJECT_ID
} else {
  "6a97bce0001ab547c5f8"
}

function Get-InstallDir {
  if ($env:FLUTTERPATCH_ROOT -and $env:FLUTTERPATCH_ROOT.Trim()) {
    return $env:FLUTTERPATCH_ROOT.Trim()
  }
  return Join-Path $env:USERPROFILE ".flutterpatch"
}

function Get-HostArch {
  $arch = $env:PROCESSOR_ARCHITECTURE
  switch -Regex ($arch) {
    "AMD64|x86_64" { return "x64" }
    "ARM64" { return "arm64" }
    default { throw "Unsupported arch: $arch" }
  }
}

function Resolve-FromCatalog {
  param([string]$Arch)

  $endpoint = if ($env:FLUTTERPATCH_DOWNLOADS_ENDPOINT) {
    $env:FLUTTERPATCH_DOWNLOADS_ENDPOINT
  } else {
    $DefaultDownloadsEndpoint
  }
  $project = if ($env:FLUTTERPATCH_DOWNLOADS_PROJECT_ID) {
    $env:FLUTTERPATCH_DOWNLOADS_PROJECT_ID
  } elseif ($env:FLUTTERPATCH_DOWNLOADS_PROJECT) {
    $env:FLUTTERPATCH_DOWNLOADS_PROJECT
  } else {
    $DefaultDownloadsProject
  }

  if (-not $endpoint -or -not $project) {
    throw "Set FLUTTERPATCH_DOWNLOADS_ENDPOINT and FLUTTERPATCH_DOWNLOADS_PROJECT_ID, or pass -Url / FLUTTERPATCH_CLI_URL."
  }

  $headers = @{
    "Content-Type"       = "application/json"
    "X-Appwrite-Project" = $project
  }
  $body = '{"action":"list_cli"}'
  Write-Host "  fetching catalog from $endpoint …"
  $resp = Invoke-RestMethod -Method Post -Uri $endpoint -Headers $headers -Body $body
  if ($resp.responseBody) {
    $resp = $resp.responseBody | ConvertFrom-Json
  }
  if ($resp.ok -eq $false) {
    throw "Catalog request failed: $($resp | ConvertTo-Json -Compress)"
  }

  $archAliases = @($Arch)
  if ($Arch -eq "x64") { $archAliases += @("amd64", "x86_64") }

  $candidates = @($resp.cli | Where-Object {
      $_.platform -and $_.platform.ToString().ToLower() -eq "windows" -and
      ($archAliases -contains $_.arch.ToString().ToLower())
    })

  if (-not $candidates -or $candidates.Count -eq 0) {
    throw "No CLI package for windows-$Arch"
  }

  $sorted = $candidates | Sort-Object {
    $_.version
  } -Descending
  $row = $sorted | Select-Object -First 1
  if (-not $row.download_url) {
    throw "Catalog row missing download_url"
  }
  return [pscustomobject]@{
    Url      = [string]$row.download_url
    Version  = [string]$row.version
    Sha256   = ([string]$row.sha256).ToLower()
    Filename = [string]$row.filename
  }
}

function Add-FlutterPatchToPath {
  param([string]$BinDir)
  $rootDir = Split-Path -Parent $BinDir
  [Environment]::SetEnvironmentVariable("FLUTTERPATCH_ROOT", $rootDir, "User")
  $env:FLUTTERPATCH_ROOT = $rootDir
  Write-Host "Set User FLUTTERPATCH_ROOT: $rootDir"

  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if (-not $userPath) { $userPath = "" }
  $parts = $userPath -split ";" | Where-Object { $_ -and $_.Trim() }
  if ($parts -contains $BinDir) {
    Write-Host "Already on User PATH: $BinDir"
    return
  }
  $newPath = if ($userPath.Trim()) { "$BinDir;$userPath" } else { $BinDir }
  [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
  $env:Path = "$BinDir;$env:Path"
  Write-Host "Added to User PATH: $BinDir"
}

# ---- main ----
$Root = Get-InstallDir
$BinDir = Join-Path $Root "bin"
$Arch = Get-HostArch
$Exe = Join-Path $BinDir "flutterpatch.exe"

Write-Host "FlutterPatch CLI installer"
Write-Host "  target: $Root"
Write-Host "  platform: windows-$Arch"

if ((Test-Path $Exe) -and (-not $Force)) {
  Write-Host "Install already present at $Root; skipping."
  Write-Host "  Upgrade CLI:  .\scripts\install.ps1 -Force"
  Write-Host "  Flutter SDKs: flutterpatch flutter install|use <version>"
  exit 0
}

if ($Force -and (Test-Path $Root)) {
  Write-Host "Reinstalling CLI (-Force); keeping Flutter cache if present…"
  $keepFlutter = $null
  $flutterCache = Join-Path $Root "bin\cache\flutter"
  if (Test-Path $flutterCache) {
    $keepFlutter = Join-Path $env:TEMP ("flutterpatch-keep-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $keepFlutter | Out-Null
    Move-Item $flutterCache (Join-Path $keepFlutter "flutter")
  }
  Remove-Item -Recurse -Force $Root
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  if ($keepFlutter -and (Test-Path (Join-Path $keepFlutter "flutter"))) {
    $destCache = Join-Path $Root "bin\cache"
    New-Item -ItemType Directory -Force -Path $destCache | Out-Null
    Move-Item (Join-Path $keepFlutter "flutter") (Join-Path $destCache "flutter")
    Remove-Item -Recurse -Force $keepFlutter -ErrorAction SilentlyContinue
  }
}

New-Item -ItemType Directory -Force -Path $Root | Out-Null

$work = Join-Path $env:TEMP ("flutterpatch-install-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
  $resolvedVersion = ""
  $cliUrl = if ($Url) { $Url } elseif ($env:FLUTTERPATCH_CLI_URL) { $env:FLUTTERPATCH_CLI_URL } else { "" }
  $archivePath = Join-Path $work "cli.zip"

  if ($cliUrl) {
    Write-Host "Downloading $cliUrl …"
    Invoke-WebRequest -UseBasicParsing -Uri $cliUrl -OutFile $archivePath
  } else {
    Write-Host "Resolving latest package from download catalog…"
    $row = Resolve-FromCatalog -Arch $Arch
    $resolvedVersion = $row.Version
    Write-Host "Downloading FlutterPatch CLI $resolvedVersion (windows-$Arch)…"
    Invoke-WebRequest -UseBasicParsing -Uri $row.Url -OutFile $archivePath
    if ($row.Sha256) {
      $hash = (Get-FileHash -Algorithm SHA256 -Path $archivePath).Hash.ToLower()
      if ($hash -ne $row.Sha256) {
        throw "sha256 mismatch (expected $($row.Sha256), got $hash)"
      }
    }
  }

  $stage = Join-Path $work "stage"
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Expand-Archive -Path $archivePath -DestinationPath $stage -Force

  $src = $null
  $nested = Join-Path $stage "flutterpatch"
  if (Test-Path (Join-Path $nested "bin")) {
    $src = $nested
  } elseif (Test-Path (Join-Path $stage "bin")) {
    $src = $stage
  } else {
    $child = Get-ChildItem $stage -Directory | Select-Object -First 1
    if ($child -and (Test-Path (Join-Path $child.FullName "bin"))) {
      $src = $child.FullName
    }
  }
  if (-not $src) {
    throw "Archive missing bin/ (expected flutterpatch\bin\...)"
  }

  Copy-Item -Path (Join-Path $src "*") -Destination $Root -Recurse -Force

  if (-not (Test-Path $Exe)) {
    throw "Expected executable at $Exe"
  }

  $reload = $false
  $pathParts = $env:Path -split ";" | Where-Object { $_ }
  if ($pathParts -notcontains $BinDir) {
    $reload = $true
    Add-FlutterPatchToPath -BinDir $BinDir
  }

  Write-Host ""
  Write-Host "FlutterPatch CLI has been installed to $Root"
  if ($resolvedVersion) { Write-Host "  version: $resolvedVersion" }

  & $Exe --help | Out-Null
  Write-Host "  binary: ok"

  if ($reload) {
    Write-Host @"

Open a new terminal to pick up PATH changes, or run:

  `$env:Path = "$BinDir;`$env:Path"

Then:

  flutterpatch flutter use <version>   # install + set default Flutter SDK
  flutterpatch doctor
  `$env:FLUTTERPATCH_TOKEN = "<dashboard token>"
  cd <your-flutter-app>; flutterpatch init
"@
  } else {
    Write-Host @"

Next:

  flutterpatch flutter use <version>   # install + set default Flutter SDK
  flutterpatch doctor
  `$env:FLUTTERPATCH_TOKEN = "<dashboard token>"
  cd <your-flutter-app>; flutterpatch init
"@
  }
}
finally {
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
