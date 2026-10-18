# Pack installable addon zip: StockPiler/<mod + Source + README>
# Usage: pwsh ./scripts/pack.ps1 [-OutDir dist]
param(
    [string]$OutDir = "dist"
)

$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$modPath = Join-Path $root "StockPiler.mod"
if (-not (Test-Path $modPath)) {
    throw "Missing StockPiler.mod at $modPath"
}

$modText = Get-Content -LiteralPath $modPath -Raw
# Prefer <UiMod ... version="x.y.z"> — not VersionSettings windowsVersion="1.0".
if ($modText -notmatch '<UiMod\b[^>]*\bversion="([^"]+)"') {
    throw "Could not read UiMod version= from StockPiler.mod"
}
$version = $Matches[1]

$outAbs = Join-Path $root $OutDir
$stageRoot = Join-Path $outAbs "_stage"
$stageAddon = Join-Path $stageRoot "StockPiler"
$zipPath = Join-Path $outAbs ("StockPiler-{0}.zip" -f $version)

if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $stageAddon -Force | Out-Null

Copy-Item -LiteralPath $modPath -Destination (Join-Path $stageAddon "StockPiler.mod")
$readme = Join-Path $root "README.md"
if (Test-Path -LiteralPath $readme) {
    Copy-Item -LiteralPath $readme -Destination (Join-Path $stageAddon "README.md")
}
Copy-Item -LiteralPath (Join-Path $root "Source") -Destination (Join-Path $stageAddon "Source") -Recurse

New-Item -ItemType Directory -Path $outAbs -Force | Out-Null
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

# Zip the StockPiler folder so extract lands as Interface/AddOns/StockPiler/
Compress-Archive -Path $stageAddon -DestinationPath $zipPath -Force
Remove-Item -LiteralPath $stageRoot -Recurse -Force

Write-Host ("Packed {0}" -f $zipPath)

if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value ("version={0}" -f $version)
    Add-Content -Path $env:GITHUB_OUTPUT -Value ("zip_path={0}" -f $zipPath)
    Add-Content -Path $env:GITHUB_OUTPUT -Value ("zip_name=StockPiler-{0}.zip" -f $version)
}
