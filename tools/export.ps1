# Export an IR child's Remote Pack to a .stir file.
#   ./tools/export.ps1 -Device <childDeviceId> -Out living-tv.stir
param(
  [Parameter(Mandatory = $true)][string]$Device,
  [Parameter(Mandatory = $true)][string]$Out
)
$ErrorActionPreference = 'Stop'
smartthings devices:commands $Device 'main:drumpepper55014.irRemotePack:exportPack' | Out-Null
Start-Sleep -Seconds 4
$status = smartthings devices:status $Device --json | ConvertFrom-Json
$share = $status.components.main.'drumpepper55014.irRemotePack'.exportData.value
if (-not $share -or -not $share.StartsWith('STIR1:')) { throw "no share string available: $share" }
$json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($share.Substring(6)))
[IO.File]::WriteAllText($Out, $json, (New-Object Text.UTF8Encoding $false))
Write-Output "wrote $Out ($($json.Length) bytes); share string length $($share.Length)"
