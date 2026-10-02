# Package, publish to the channel and install on the hub in one step.
#   ./tools/deploy.ps1                 (defaults below)
#   ./tools/deploy.ps1 -Hub <hubId> -Channel <channelId>
param(
  [string]$Channel = 'a90df459-0afc-4028-8073-31a415cc85e7',
  [string]$Hub = 'fb9610df-2d91-4124-980c-aa0a319952b2'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out = smartthings edge:drivers:package $root --json 2>&1 | Out-String
$pkg = $out | ConvertFrom-Json
if (-not $pkg.driverId) { throw "package failed:`n$out" }
Write-Output "packaged $($pkg.driverId) version $($pkg.version)"
smartthings edge:channels:assign $pkg.driverId --channel $Channel | Out-Null
smartthings edge:drivers:install $pkg.driverId --channel $Channel --hub $Hub | Out-Null
Write-Output "installed on hub $Hub"
