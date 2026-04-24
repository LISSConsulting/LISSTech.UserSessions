set shell := ["pwsh", "-NoProfile", "-Command"]
set dotenv-load

# Paths
module_name := "LISSTech.UserSessions"
release_dir := justfile_directory() / "Release" / module_name

# Code signing (set CODE_SIGNING_CERTIFICATE_THUMBPRINT in .env or environment)
signing_thumbprint := env("CODE_SIGNING_CERTIFICATE_THUMBPRINT", "")
timestamp_url      := "http://timestamp.digicert.com"

# PSGallery (set PSGALLERY_API_KEY in .env or environment)
psgallery_key := env("PSGALLERY_API_KEY", "")

# Install target (override with MODULE_INSTALL_PATH)
install_path := env("MODULE_INSTALL_PATH", "")

[private]
default:
    @just --list

# ── Version ─────────────────────────────────────────────────────────────────

# Bump CalVer (YY.DOY.patch) in module manifest
[script('pwsh', '-NoProfile')]
[extension('.ps1')]
bump:
    $ErrorActionPreference = 'Stop'
    & '{{ justfile_directory() }}/scripts/Bump-Version.ps1'
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# ── Lint ────────────────────────────────────────────────────────────────────

# Apply UTF-8 BOM to every .ps1 / .psm1 / .psd1 / .md
[script('pwsh', '-NoProfile')]
[extension('.ps1')]
bom:
    $ErrorActionPreference = 'Stop'
    Write-Host "`n📝 Applying UTF-8 BOM" -ForegroundColor Cyan
    & '{{ justfile_directory() }}/scripts/Apply-Bom.ps1'
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Verify BOMs are present (no changes)
[script('pwsh', '-NoProfile')]
[extension('.ps1')]
bom-check:
    $ErrorActionPreference = 'Stop'
    & '{{ justfile_directory() }}/scripts/Apply-Bom.ps1' -Check
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# BOM verification + PSScriptAnalyzer
[script('pwsh', '-NoProfile')]
[extension('.ps1')]
lint:
    $ErrorActionPreference = 'Stop'
    Write-Host "`n🔍 Verifying BOMs" -ForegroundColor Cyan
    & '{{ justfile_directory() }}/scripts/Apply-Bom.ps1' -Check
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Host "   ✅ All files have BOM" -ForegroundColor Green

    Write-Host "`n🔍 PSScriptAnalyzer" -ForegroundColor Cyan
    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        Write-Host "   ❌ PSScriptAnalyzer not installed" -ForegroundColor Red
        Write-Host "      Install with: Install-Module PSScriptAnalyzer -Scope CurrentUser" -ForegroundColor DarkGray
        exit 1
    }
    $pssaArgs = @{
        Path         = '{{ justfile_directory() }}'
        Recurse      = $true
        ExcludeRule  = 'PSAvoidUsingWriteHost'
    }
    $results = Invoke-ScriptAnalyzer @pssaArgs |
        Where-Object {
            $_.ScriptPath -notlike '*\Release\*' -and
            $_.ScriptPath -notlike '*\dist\*' -and
            $_.ScriptPath -notlike '*\.git\*'
        }
    if ($results) {
        $results | Format-Table -AutoSize
        Write-Host "   ❌ $($results.Count) issue(s) found" -ForegroundColor Red
        exit 1
    }
    Write-Host "   ✅ Clean" -ForegroundColor Green

# ── Test ────────────────────────────────────────────────────────────────────

# Run Pester test suite
[script('pwsh', '-NoProfile')]
[extension('.ps1')]
test:
    $ErrorActionPreference = 'Stop'
    Write-Host "`n🧪 Running Pester tests" -ForegroundColor Cyan
    if (-not (Get-Module -ListAvailable Pester)) {
        Write-Host "   ❌ Pester not installed" -ForegroundColor Red
        Write-Host "      Install with: Install-Module Pester -Scope CurrentUser" -ForegroundColor DarkGray
        exit 1
    }
    $result = Invoke-Pester -Path '{{ justfile_directory() }}/tests' -Output Detailed -PassThru
    if ($result.FailedCount -gt 0) {
        Write-Host "   ❌ $($result.FailedCount) test(s) failed" -ForegroundColor Red
        exit 1
    }
    Write-Host "   ✅ $($result.PassedCount) test(s) passed" -ForegroundColor Green

# ── Assemble ────────────────────────────────────────────────────────────────

# Copy module files into Release/LISSTech.UserSessions/
[private]
[script('pwsh', '-NoProfile')]
[extension('.ps1')]
assemble:
    $ErrorActionPreference = 'Stop'
    $root   = '{{ justfile_directory() }}'
    $outDir = '{{ release_dir }}'

    if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    Write-Host "`n📦 Assembling module" -ForegroundColor Cyan

    $files = @(
        'LISSTech.UserSessions.psd1',
        'LISSTech.UserSessions.psm1',
        'README.md',
        'LICENSE',
        'CHANGELOG.md',
        'profile-snippet.ps1'
    )
    foreach ($f in $files) {
        $src = Join-Path $root $f
        if (-not (Test-Path $src)) {
            Write-Host "   ❌ Missing: $f" -ForegroundColor Red
            exit 1
        }
        Copy-Item $src $outDir -Force
        Write-Host "   $f" -ForegroundColor DarkGray
    }

    foreach ($dir in @('Private', 'Public')) {
        $src = Join-Path $root $dir
        if (-not (Test-Path $src)) {
            Write-Host "   ❌ Missing: $dir/" -ForegroundColor Red
            exit 1
        }
        Copy-Item $src $outDir -Recurse -Force
        $count = (Get-ChildItem $src -Filter *.ps1).Count
        Write-Host "   $dir/ ($count files)" -ForegroundColor DarkGray
    }

    $version = (Import-PowerShellDataFile (Join-Path $outDir 'LISSTech.UserSessions.psd1')).ModuleVersion
    Write-Host "   ✅ Module assembled at: $outDir (v$version)" -ForegroundColor Green

# ── Sign ────────────────────────────────────────────────────────────────────

# Authenticode-sign .ps1/.psm1/.psd1 in Release/
[script('pwsh', '-NoProfile')]
[extension('.ps1')]
sign:
    $ErrorActionPreference = 'Stop'
    $thumbprint = '{{ signing_thumbprint }}'
    if (-not $thumbprint) {
        Write-Host "`n⏭️  Skipping signing (no certificate)" -ForegroundColor Yellow
        exit 0
    }

    $outDir = '{{ release_dir }}'
    if (-not (Test-Path $outDir)) {
        Write-Host "`n❌ Release not found — run 'just assemble' first." -ForegroundColor Red
        exit 1
    }

    $cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -CodeSigningCert |
        Where-Object Thumbprint -eq $thumbprint |
        Select-Object -First 1
    if (-not $cert) {
        Write-Host "`n❌ Certificate with thumbprint $thumbprint not found" -ForegroundColor Red
        exit 1
    }

    $cn = $cert.Subject -replace '^CN=', '' -replace ',.*', ''
    Write-Host "`n🔏 Signing module files" -ForegroundColor Cyan
    Write-Host "   Certificate: $cn" -ForegroundColor DarkGray
    Write-Host "   Thumbprint:  $($thumbprint.Substring(0,8))..." -ForegroundColor DarkGray

    $tsUrl = '{{ timestamp_url }}'
    $files = Get-ChildItem $outDir -Recurse -Include *.ps1, *.psm1, *.psd1 -File
    foreach ($file in $files) {
        $name = $file.FullName.Substring($outDir.Length).TrimStart('\', '/')
        Set-AuthenticodeSignature -FilePath $file.FullName -Certificate $cert `
            -TimestampServer $tsUrl -HashAlgorithm SHA256 | Out-Null
        $status = (Get-AuthenticodeSignature $file.FullName).Status
        if ($status -ne 'Valid') {
            Write-Host "   ❌ $name ($status)" -ForegroundColor Red
            exit 1
        }
        Write-Host "   ✅ $name" -ForegroundColor Green
    }

# ── Release ─────────────────────────────────────────────────────────────────

# lint → test → assemble → sign
[script('pwsh', '-NoProfile')]
[extension('.ps1')]
release: lint test assemble sign
    $outDir  = '{{ release_dir }}'
    $version = (Import-PowerShellDataFile (Join-Path $outDir 'LISSTech.UserSessions.psd1')).ModuleVersion
    $size    = (Get-ChildItem $outDir -Recurse -File | Measure-Object Length -Sum).Sum / 1KB
    Write-Host ""
    Write-Host "🚀 Release complete" -ForegroundColor Green
    Write-Host ("   Module       {0}" -f '{{ module_name }}') -ForegroundColor DarkGray
    Write-Host ("   Version      {0}" -f $version) -ForegroundColor DarkGray
    Write-Host ("   Size         {0,6:N0} KB" -f $size) -ForegroundColor DarkGray
    Write-Host ("   Location     {0}" -f $outDir) -ForegroundColor DarkGray
    Write-Host ""

# ── Publish ─────────────────────────────────────────────────────────────────

# Build, sign, and publish to PowerShell Gallery
publish: release publish-gallery

# Publish assembled module to PSGallery (standalone, for retries)
[script('pwsh', '-NoProfile')]
[extension('.ps1')]
publish-gallery:
    $ErrorActionPreference = 'Stop'
    $psKey = '{{ psgallery_key }}'
    if (-not $psKey) {
        Write-Host "`n❌ PSGALLERY_API_KEY not set" -ForegroundColor Red
        exit 1
    }

    $outDir = '{{ release_dir }}'
    $manifest = Join-Path $outDir 'LISSTech.UserSessions.psd1'
    if (-not (Test-Path $manifest)) {
        Write-Host "`n❌ Module not found — run 'just release' first." -ForegroundColor Red
        exit 1
    }

    $version = (Import-PowerShellDataFile $manifest).ModuleVersion
    Write-Host "`n📤 Publishing {{ module_name }} v$version to PSGallery" -ForegroundColor Cyan

    Publish-Module -Path $outDir -NuGetApiKey $psKey -ErrorAction Stop
    Write-Host "   ✅ {{ module_name }} v$version published" -ForegroundColor Green
    Write-Host ""

# ── Install ─────────────────────────────────────────────────────────────────

# Install assembled module into the local module path (override with MODULE_INSTALL_PATH)
[script('pwsh', '-NoProfile')]
[extension('.ps1')]
install: assemble
    $ErrorActionPreference = 'Stop'
    $outDir = '{{ release_dir }}'
    $manifest = Join-Path $outDir 'LISSTech.UserSessions.psd1'
    if (-not (Test-Path $manifest)) {
        Write-Host "`n❌ Module not found — run 'just assemble' first." -ForegroundColor Red
        exit 1
    }

    $version = (Import-PowerShellDataFile $manifest).ModuleVersion

    $target = '{{ install_path }}'
    if (-not $target) {
        $target = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'
    }
    $dest = Join-Path $target '{{ module_name }}' $version

    Write-Host "`n🏠 Installing {{ module_name }} v$version" -ForegroundColor Cyan
    Write-Host "   Target: $dest" -ForegroundColor DarkGray

    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item (Join-Path $outDir '*') $dest -Recurse -Force
    Write-Host "   ✅ Installed" -ForegroundColor Green

# ── Clean ───────────────────────────────────────────────────────────────────

# Remove Release/ and stray build artifacts
[script('pwsh', '-NoProfile')]
[extension('.ps1')]
clean:
    $ErrorActionPreference = 'Stop'
    Write-Host "`n🧹 Cleaning" -ForegroundColor Cyan
    $root = '{{ justfile_directory() }}'
    foreach ($path in @('Release', 'dist')) {
        $full = Join-Path $root $path
        if (Test-Path $full) {
            Remove-Item $full -Recurse -Force
            Write-Host "   Removed $path/" -ForegroundColor DarkGray
        }
    }
    Get-ChildItem $root -Recurse -Include *.bak, TestResults, coverage.xml -Force `
        -ErrorAction SilentlyContinue |
        ForEach-Object {
            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "   Removed $($_.Name)" -ForegroundColor DarkGray
        }
    Write-Host "   ✅ Clean" -ForegroundColor Green
