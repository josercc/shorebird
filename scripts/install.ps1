# FlutterPatch CLI one-click install (Windows PowerShell).
#
# Usage:
#   iwr -UseBasicParsing https://<site>/downloads/install_cli.ps1 | iex
#   .\scripts\install.ps1 -Force
#   .\scripts\install.ps1 -Archive .\dist\cli\flutterpatch-cli-1.0.0-windows-x64.zip
#
# Environment:
#   FLUTTERPATCH_ROOT
#   FLUTTERPATCH_DOWNLOADS_ENDPOINT
#   FLUTTERPATCH_DOWNLOADS_PROJECT_ID
#   FLUTTERPATCH_CLI_URL
#   FLUTTERPATCH_FLUTTER_GIT_URL
#   FLUTTER_STORAGE_BASE_URL

[CmdletBinding()]
param(
  [switch]$Force,
  [string]$Version = "",
  [string]$Archive = "",
  [string]$Url = "",
  [switch]$SkipPath,
  [switch]$SkipFlutter
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
$FlutterGitUrl = if ($env:FLUTTERPATCH_FLUTTER_GIT_URL) {
  $env:FLUTTERPATCH_FLUTTER_GIT_URL
} else {
  "https://github.com/shorebirdtech/flutter.git"
}
$EngineCdn = if ($env:FLUTTER_STORAGE_BASE_URL) {
  $env:FLUTTER_STORAGE_BASE_URL
} else {
  "https://download.shorebird.dev"
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
  param([string]$Arch, [string]$WantVersion)

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
    throw "Set FLUTTERPATCH_DOWNLOADS_ENDPOINT and FLUTTERPATCH_DOWNLOADS_PROJECT_ID, or pass -Url / -Archive."
  }

  $headers = @{
    "Content-Type"        = "application/json"
    "X-Appwrite-Project"  = $project
  }
  $body = '{"action":"list_cli"}'
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

  if ($WantVersion) {
    $wantN = $WantVersion.TrimStart("v", "V")
    $candidates = @($candidates | Where-Object {
        $_.version.ToString().TrimStart("v", "V") -eq $wantN
      })
  }

  if (-not $candidates -or $candidates.Count -eq 0) {
    throw "No CLI package for windows-$Arch$(if ($WantVersion) { " version $WantVersion" })"
  }

  $sorted = $candidates | Sort-Object {
    # Best-effort: newer first by string version.
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

function Init-FlutterToolchain {
  param([string]$Root)

  $versionFile = Join-Path $Root "bin\internal\flutter.version"
  if (-not (Test-Path $versionFile)) {
    Write-Warning "Missing $versionFile; skipping Flutter init"
    return
  }
  $rev = (Get-Content $versionFile -Raw).Trim()
  if (-not $rev) {
    Write-Warning "Empty flutter.version; skipping Flutter init"
    return
  }

  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git is required to initialize the Flutter toolchain"
  }

  $flutterPath = Join-Path $Root "bin\cache\flutter\$rev"
  New-Item -ItemType Directory -Force -Path (Split-Path $flutterPath) | Out-Null

  $flutterBat = Join-Path $flutterPath "bin\flutter.bat"
  if (Test-Path $flutterBat) {
    Write-Host "Flutter SDK already present at $flutterPath"
  } else {
    Write-Host "Installing Shorebird Flutter ($rev)…"
    if (Test-Path $flutterPath) { Remove-Item -Recurse -Force $flutterPath }
    & git clone --filter=tree:0 $FlutterGitUrl --no-checkout $flutterPath
    & git -C $flutterPath -c advice.detachedHead=false checkout $rev
  }

  Write-Host "Bootstrapping Flutter engine artifacts…"
  $env:FLUTTER_STORAGE_BASE_URL = $EngineCdn
  & $flutterBat --disable-analytics 2>$null | Out-Null
  & $flutterBat --version
}

# ---- main ----
$Root = Get-InstallDir
$BinDir = Join-Path $Root "bin"
$Arch = Get-HostArch

Write-Host "FlutterPatch CLI installer"
Write-Host "  target: $Root"
Write-Host "  platform: windows-$Arch"

if (Test-Path $Root) {
  if (-not $Force) {
    throw "Existing FlutterPatch installation at $Root. Use -Force to overwrite."
  }
  Write-Host "Existing install detected. Overwriting (-Force)…"
  $keepFlutter = $null
  $flutterCache = Join-Path $Root "bin\cache\flutter"
  if ((-not $SkipFlutter) -and (Test-Path $flutterCache)) {
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
} else {
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
}

$work = Join-Path $env:TEMP ("flutterpatch-install-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
  $archivePath = $null
  $resolvedVersion = ""
  $cliUrl = if ($Url) { $Url } elseif ($env:FLUTTERPATCH_CLI_URL) { $env:FLUTTERPATCH_CLI_URL } else { "" }

  if ($Archive) {
    if (-not (Test-Path $Archive)) { throw "Archive not found: $Archive" }
    $archivePath = (Resolve-Path $Archive).Path
    Write-Host "Using local archive: $archivePath"
  } elseif ($cliUrl) {
    $archivePath = Join-Path $work "cli.zip"
    Write-Host "Downloading $cliUrl …"
    Invoke-WebRequest -UseBasicParsing -Uri $cliUrl -OutFile $archivePath
  } else {
    Write-Host "Resolving latest package from download catalog…"
    $row = Resolve-FromCatalog -Arch $Arch -WantVersion $Version
    $resolvedVersion = $row.Version
    $archivePath = Join-Path $work "cli.zip"
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

  $exe = Join-Path $BinDir "flutterpatch.exe"
  if (-not (Test-Path $exe)) {
    throw "Expected executable at $exe"
  }

  if (-not $SkipFlutter) {
    Init-FlutterToolchain -Root $Root
  } else {
    Write-Host "Skipping Flutter SDK init (-SkipFlutter). It will download on first release/patch."
  }

  $reload = $false
  $pathParts = $env:Path -split ";" | Where-Object { $_ }
  if ($pathParts -notcontains $BinDir) {
    $reload = $true
    if (-not $SkipPath) {
      Add-FlutterPatchToPath -BinDir $BinDir
    }
  }

  Write-Host ""
  Write-Host "FlutterPatch CLI has been installed to $Root"
  if ($resolvedVersion) { Write-Host "  version: $resolvedVersion" }

  & $exe --help | Out-Null
  Write-Host "  binary: ok"

  if ($reload) {
    Write-Host @"

Open a new terminal to pick up PATH changes, or run:

  `$env:Path = "$BinDir;`$env:Path"

Then:

  flutterpatch doctor
  `$env:FLUTTERPATCH_TOKEN = "<dashboard token>"
  cd <your-flutter-app>; flutterpatch init
"@
  } else {
    Write-Host @"

Next:

  flutterpatch doctor
  `$env:FLUTTERPATCH_TOKEN = "<dashboard token>"
  cd <your-flutter-app>; flutterpatch init
"@
  }
}
finally {
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
