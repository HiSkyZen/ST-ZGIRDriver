# Import a file (Remote Pack .stir, SmartIR JSON, LIRC conf, Pronto, Broadlink,
# Global Cache, raw timings, "name: code" lines) into an IR child device.
# Large files are sent as "@part i/n" chunks which the driver reassembles.
#   ./tools/import.ps1 -Device <childDeviceId> -File remote.json
param(
  [Parameter(Mandatory = $true)][string]$Device,
  [Parameter(Mandatory = $true)][string]$File,
  [int]$ChunkSize = 8000
)
$ErrorActionPreference = 'Stop'
$text = (Get-Content -Raw -Encoding UTF8 $File).Trim()
$n = [Math]::Max(1, [Math]::Ceiling($text.Length / $ChunkSize))
for ($i = 0; $i -lt $n; $i++) {
  $part = $text.Substring($i * $ChunkSize, [Math]::Min($ChunkSize, $text.Length - $i * $ChunkSize))
  $payload = if ($n -gt 1) { "@part $($i + 1)/$n $part" } else { $part }
  $arg = $payload | ConvertTo-Json -Compress
  smartthings devices:commands $Device "main:drumpepper55014.irRemotePack:importData($arg)" | Out-Null
  Write-Output "sent part $($i + 1)/$n"
}
