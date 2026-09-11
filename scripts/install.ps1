# FlutterPatch CLI one-click install (Windows PowerShell).
#
# Usage:
#   iwr -UseBasicParsing https://<site>/downloads/install_cli.ps1 | iex
#   .\scripts\install.ps1                 # resume / repair if already present
#   .\scripts\install.ps1 -Force          # reinstall CLI (keeps Flutter cache)
#   .\scripts\install.ps1 -FlutterVersion 3.27.4
#   .\scripts\install.ps1 -Archive .\dist\cli\flutterpatch-cli-1.0.0-windows-x64.zip
#
# Re-running after a failure resumes: skips CLI download when the binary
# exists, resumes an interrupted Flutter git checkout, and skips engine
# bootstrap when the toolchain cache is already present. Use -Force to
# re-download/overwrite the CLI package.
#
# Prefer -FlutterVersion <semver|git-hash> to install only the Flutter SDK
# you will release/patch with. Or pass -SkipFlutter to defer download.
#
# Environment:
#   FLUTTERPATCH_ROOT
#   FLUTTERPATCH_DOWNLOADS_ENDPOINT
#   FLUTTERPATCH_DOWNLOADS_PROJECT_ID
#   FLUTTERPATCH_CLI_URL
#   FLUTTERPATCH_FLUTTER_GIT_URL
#   FLUTTERPATCH_ENGINE_CDN           engine CDN (default: download.shorebird.dev)
#   FLUTTER_STORAGE_BASE_URL          ignored during install (cleared; China Flutter
#                                     mirrors do not host Shorebird engines)

[CmdletBinding()]
param(
  [switch]$Force,
  [string]$Version = "",
  [string]$FlutterVersion = "",
  [string]$Archive = "",
  [string]$Url = "",
  [switch]$SkipPath,
  [switch]$SkipFlutter
)

$ErrorActionPreference = "Stop"

if ($FlutterVersion -and $SkipFlutter) {
  throw "-FlutterVersion and -SkipFlutter cannot be used together."
}

# Shorebird engine artifacts only live on download.shorebird.dev. Clear any
# inherited Flutter China mirror so bootstrap cannot download a 404 XML page.
if ($env:FLUTTER_STORAGE_BASE_URL) {
  Write-Host "Ignoring FLUTTER_STORAGE_BASE_URL=$($env:FLUTTER_STORAGE_BASE_URL) (Shorebird engines are not on Flutter mirrors)"
  Remove-Item Env:\FLUTTER_STORAGE_BASE_URL -ErrorAction SilentlyContinue
}

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
$EngineCdn = if ($env:FLUTTERPATCH_ENGINE_CDN) {
  $env:FLUTTERPATCH_ENGINE_CDN
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

function Resolve-FlutterRevision {
  param([string]$Want)

  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git is required to resolve --flutter-version / -FlutterVersion"
  }

  $Want = $Want.Trim().TrimStart("v", "V")
  if (-not $Want) { throw "Empty -FlutterVersion" }

  if ($Want -match '^[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.+-]*)?$') {
    Write-Host "Resolving Flutter $Want via flutter_release/$Want …"
    $line = & git ls-remote --heads $FlutterGitUrl "refs/heads/flutter_release/$Want" |
      Select-Object -First 1
    if (-not $line) {
      throw "No Shorebird Flutter release branch flutter_release/$Want"
    }
    return ($line -split '\s+')[0]
  }

  if ($Want -match '^[0-9a-fA-F]{7,40}$') {
    Write-Host "Resolving Flutter git revision $Want …"
    $line = & git ls-remote $FlutterGitUrl $Want | Select-Object -First 1
    if ($line) {
      return ($line -split '\s+')[0]
    }
    if ($Want.Length -ge 40) {
      return $Want.ToLower()
    }
    throw "Could not resolve git revision $Want on $FlutterGitUrl"
  }

  throw "-FlutterVersion must be a Flutter semver (e.g. 3.27.4) or git hash."
}

function Set-FlutterVersionPin {
  param([string]$Root, [string]$Rev, [string]$Label)
  $versionFile = Join-Path $Root "bin\internal\flutter.version"
  New-Item -ItemType Directory -Force -Path (Split-Path $versionFile) | Out-Null
  Set-Content -Path $versionFile -Value $Rev -NoNewline
  Write-Host "Pinned Flutter $Label → $Rev ($versionFile)"
}

function Remove-OtherFlutterSdks {
  param([string]$Root, [string]$KeepRev)
  $cache = Join-Path $Root "bin\cache\flutter"
  if (-not (Test-Path $cache)) { return }
  Get-ChildItem $cache -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Name -ne $KeepRev) {
      Write-Host "Removing unused Flutter cache: $($_.FullName)"
      Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue
    }
  }
}

function Test-FlutterToolchainBootstrapped {
  param([string]$FlutterPath)
  $dartExe = Join-Path $FlutterPath "bin\cache\dart-sdk\bin\dart.exe"
  if (-not (Test-Path $dartExe)) { return $false }
  $stamps = @(
    (Join-Path $FlutterPath "bin\cache\flutter_tools.stamp"),
    (Join-Path $FlutterPath "bin\cache\flutter_tools.snapshot"),
    (Join-Path $FlutterPath "bin\cache\flutter_tools.dill")
  )
  foreach ($s in $stamps) {
    if (Test-Path $s) { return $true }
  }
  return $false
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
  $gitDir = Join-Path $flutterPath ".git"
  if (Test-Path $flutterBat) {
    Write-Host "Flutter SDK already present at $flutterPath"
  } elseif (Test-Path $gitDir) {
    Write-Host "Resuming incomplete Flutter checkout ($rev)…"
    & git -C $flutterPath -c advice.detachedHead=false fetch --filter=tree:0 origin $rev
    & git -C $flutterPath -c advice.detachedHead=false checkout $rev
  } else {
    Write-Host "Installing Shorebird Flutter ($rev)…"
    if (Test-Path $flutterPath) { Remove-Item -Recurse -Force $flutterPath }
    & git clone --filter=tree:0 $FlutterGitUrl --no-checkout $flutterPath
    & git -C $flutterPath -c advice.detachedHead=false checkout $rev
  }

  if (Test-FlutterToolchainBootstrapped -FlutterPath $flutterPath) {
    Write-Host "Flutter engine artifacts already present; skipping bootstrap"
    Remove-OtherFlutterSdks -Root $Root -KeepRev $rev
    return
  }

  # Clear incomplete bootstrap leftovers so Flutter can re-download cleanly.
  $cacheDir = Join-Path $flutterPath "bin\cache"
  Remove-Item -Recurse -Force (Join-Path $cacheDir "dart-sdk") -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force (Join-Path $cacheDir "dart-sdk.old") -ErrorAction SilentlyContinue
  Get-ChildItem $cacheDir -Filter "dart-sdk-*.zip" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

  Write-Host "Bootstrapping Flutter engine artifacts…"
  $env:FLUTTER_STORAGE_BASE_URL = $EngineCdn
  & $flutterBat --disable-analytics 2>$null | Out-Null
  & $flutterBat --version

  Remove-OtherFlutterSdks -Root $Root -KeepRev $rev
}

# ---- main ----
$Root = Get-InstallDir
$BinDir = Join-Path $Root "bin"
$Arch = Get-HostArch

Write-Host "FlutterPatch CLI installer"
Write-Host "  target: $Root"
Write-Host "  platform: windows-$Arch"

$Resume = $false
if (Test-Path $Root) {
  if ($Force) {
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
    $Resume = $true
    Write-Host "Existing install detected at $Root; resuming (use -Force to reinstall CLI)…"
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
  $exe = Join-Path $BinDir "flutterpatch.exe"
  $skipCliPackage = $Resume -and (Test-Path $exe) -and (-not $Archive) -and (-not $cliUrl) -and (-not $Version)

  if ($skipCliPackage) {
    Write-Host "CLI binary already present; skipping download"
  } elseif ($Archive) {
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

  if (-not $skipCliPackage) {
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
  }

  if (-not (Test-Path $exe)) {
    throw "Expected executable at $exe"
  }

  if ($FlutterVersion) {
    $resolvedFlutterRev = Resolve-FlutterRevision -Want $FlutterVersion
    Set-FlutterVersionPin -Root $Root -Rev $resolvedFlutterRev -Label $FlutterVersion
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
