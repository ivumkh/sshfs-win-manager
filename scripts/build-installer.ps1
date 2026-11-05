<#
.SYNOPSIS
  Builds the Windows NSIS installer using a project-local toolchain.

.DESCRIPTION
  Nothing is installed globally and no global config is used:
    - a portable Node.js is downloaded once into .tools\node (SHA-256 verified)
    - npm, Electron and electron-builder download caches live under .cache\
    - npm reads .cache\npmrc instead of ~/.npmrc (put registry auth there if needed)
  Output: build\sshfs-win-manager-setup-v<version>.exe

.PARAMETER SkipInstall
  Skip `npm ci` and reuse the existing node_modules.

.PARAMETER Registry
  npm registry to use (default: https://registry.npmjs.org/).
#>
param(
  [switch]$SkipInstall,
  [string]$Registry
)

$ErrorActionPreference = 'Stop'

# Node 16 is the newest line that works with webpack 4 / babel 6 / electron-builder 20
# without OpenSSL workarounds, and its npm 8 understands lockfileVersion 3.
$nodeVersion = 'v16.20.2'

$root    = Split-Path -Parent $PSScriptRoot
$tools   = Join-Path $root '.tools'
$nodeDir = Join-Path $tools 'node'
$cache   = Join-Path $root '.cache'
$nodeExe = Join-Path $nodeDir 'node.exe'

function Install-LocalNode {
  $zipName = "node-$nodeVersion-win-x64.zip"
  $baseUrl = "https://nodejs.org/dist/$nodeVersion"
  $dl      = Join-Path $tools 'dl'

  if (Test-Path $nodeDir) { Remove-Item -Recurse -Force $nodeDir }
  New-Item -ItemType Directory -Force $dl | Out-Null

  try {
    $zip = Join-Path $dl $zipName
    Write-Host "Downloading Node.js $nodeVersion ..."
    Invoke-WebRequest "$baseUrl/$zipName" -OutFile $zip -UseBasicParsing
    $sums = (Invoke-WebRequest "$baseUrl/SHASUMS256.txt" -UseBasicParsing).Content

    $expected = ($sums -split "`n" | Where-Object { $_ -match "\s$([regex]::Escape($zipName))$" }) -replace '\s.*$', ''
    $actual   = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if (-not $expected -or $actual -ne $expected.Trim().ToLower()) {
      throw "SHA-256 mismatch for $zipName (expected '$expected', got '$actual')"
    }

    Expand-Archive $zip -DestinationPath $dl
    Move-Item (Join-Path $dl "node-$nodeVersion-win-x64") $nodeDir
  } finally {
    Remove-Item -Recurse -Force $dl -ErrorAction SilentlyContinue
  }
}

if (-not (Test-Path $nodeExe) -or (& $nodeExe --version) -ne $nodeVersion) {
  Install-LocalNode
}

$npmrc = Join-Path $cache 'npmrc'
if (-not (Test-Path $npmrc)) {
  New-Item -ItemType Directory -Force $cache | Out-Null
  New-Item -ItemType File $npmrc | Out-Null
}

$env:Path                   = "$nodeDir;$env:Path"
$env:npm_config_userconfig  = $npmrc
$env:npm_config_cache       = Join-Path $cache 'npm'
$env:npm_config_prefix      = Join-Path $tools 'npm-global'   # guard against accidental -g installs
$env:npm_config_update_notifier = 'false'
if ($Registry) { $env:npm_config_registry = $Registry }
$env:electron_config_cache  = Join-Path $cache 'electron'     # electron's postinstall download
$env:ELECTRON_CACHE         = Join-Path $cache 'electron'     # electron-builder's Electron download
$env:ELECTRON_BUILDER_CACHE = Join-Path $cache 'electron-builder' # NSIS, winCodeSign, ...

Write-Host "Using node $(node --version), npm $(npm --version), registry $(npm config get registry)"

Push-Location $root
try {
  if (-not $SkipInstall) {
    npm ci
    if ($LASTEXITCODE) { throw "npm ci failed ($LASTEXITCODE)" }
  }

  npm run build
  if ($LASTEXITCODE) { throw "npm run build failed ($LASTEXITCODE)" }

  Get-ChildItem (Join-Path $root 'build') -Filter '*.exe' | Select-Object Name, Length, LastWriteTime
} finally {
  Pop-Location
}
