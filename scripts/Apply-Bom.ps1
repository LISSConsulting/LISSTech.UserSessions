<#
.SYNOPSIS
    Apply UTF-8 BOM to every .ps1 / .psm1 / .psd1 / .md in the repo, or
    verify (in -Check mode) that every such file already has one.

.DESCRIPTION
    Windows PowerShell 5.1 defaults to the OEM codepage (437 / 1252) when
    reading unmarked files, which mangles the Unicode box-drawing and
    status glyphs this module relies on. Every source file must start
    with the BOM bytes EF BB BF.

.PARAMETER Check
    Exit non-zero if any file is missing its BOM. Prints the offenders
    to stderr. Used by `just lint` in CI.
#>

[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$bom      = [byte[]](0xEF, 0xBB, 0xBF)

$files = Get-ChildItem -Path $repoRoot -Recurse -File -Include *.ps1, *.psm1, *.psd1, *.md |
    Where-Object FullName -notlike '*\dist\*' |
    Where-Object FullName -notlike '*\.git\*'

$missing = @()
$applied = @()

foreach ($f in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = $bytes.Length -ge 3 -and
              $bytes[0] -eq 0xEF -and
              $bytes[1] -eq 0xBB -and
              $bytes[2] -eq 0xBF

    if (-not $hasBom) {
        if ($Check) {
            $missing += $f.FullName
        } else {
            $newBytes = New-Object byte[] ($bytes.Length + 3)
            [Array]::Copy($bom, 0, $newBytes, 0, 3)
            [Array]::Copy($bytes, 0, $newBytes, 3, $bytes.Length)
            [System.IO.File]::WriteAllBytes($f.FullName, $newBytes)
            $applied += $f.FullName
        }
    }
}

if ($Check) {
    if ($missing.Count -gt 0) {
        Write-Host "BOM missing on $($missing.Count) file(s):" -ForegroundColor Red
        $missing | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        exit 1
    } else {
        Write-Host "BOM check passed — all $($files.Count) files have UTF-8 BOM." -ForegroundColor Green
    }
} else {
    if ($applied.Count -gt 0) {
        Write-Host "Applied BOM to $($applied.Count) file(s):" -ForegroundColor Yellow
        $applied | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    } else {
        Write-Host "All $($files.Count) files already have BOM — no action taken." -ForegroundColor Green
    }
}
