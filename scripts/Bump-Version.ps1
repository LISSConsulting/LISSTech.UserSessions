<#
.SYNOPSIS
    Bump the module's CalVer (YY.DOY.patch) in the manifest.

.DESCRIPTION
    CalVer logic:
      - Year and day-of-year come from the current date.
      - If the manifest already has today's Y.D, the patch is incremented.
      - Otherwise (new day), version resets to YY.DOY.0.

    Example transitions (on day 113 of 2026):
      26.112.3  → 26.113.0   (new day)
      26.113.0  → 26.113.1   (bugfix same day)
      26.113.7  → 26.113.8   (repeated bumps same day)
#>

[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'LISSTech.UserSessions.psd1')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ManifestPath)) {
    throw "Manifest not found at: $ManifestPath"
}

$manifest = Import-PowerShellDataFile $ManifestPath
$current  = [string]$manifest.ModuleVersion

$today = Get-Date
$yy    = $today.ToString('yy')
$doy   = $today.DayOfYear

$parts = $current -split '\.'
$sameDay = ($parts.Count -eq 3) -and
           ($parts[0] -eq $yy) -and
           ([int]$parts[1] -eq $doy)

$newVersion = if ($sameDay) {
    '{0}.{1}.{2}' -f $yy, $doy, ([int]$parts[2] + 1)
} else {
    '{0}.{1}.0' -f $yy, $doy
}

$content = Get-Content -Path $ManifestPath -Raw
$pattern = "ModuleVersion\s*=\s*'[^']+'"
$replace = "ModuleVersion        = '$newVersion'"
$newContent = [regex]::Replace($content, $pattern, $replace, 1)

if ($content -eq $newContent) {
    throw "Could not locate ModuleVersion line in $ManifestPath — manifest format unexpected."
}

# Preserve UTF-8 BOM encoding
[System.IO.File]::WriteAllText($ManifestPath, $newContent, (New-Object System.Text.UTF8Encoding $true))

Write-Host "Version bumped: $current → $newVersion" -ForegroundColor Green
