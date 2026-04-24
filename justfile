# ---------------------------------------------------------------------------
# LISSTech.UserSessions — build recipes
# Run `just` with no args to list available targets.
# ---------------------------------------------------------------------------

set dotenv-load := true
set windows-shell := ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command"]

module_name   := 'LISSTech.UserSessions'
manifest_path := module_name + '.psd1'
dist_dir      := 'dist'

# ---------------------------------------------------------------------------
# Default: print available recipes
# ---------------------------------------------------------------------------
default:
    @just --list

# ---------------------------------------------------------------------------
# 🧪 Run Pester test suite
# ---------------------------------------------------------------------------
test:
    Invoke-Pester -Path tests/ -Output Detailed

# ---------------------------------------------------------------------------
# 🔍 PSScriptAnalyzer + BOM verification
# ---------------------------------------------------------------------------
lint: bom-check
    Invoke-ScriptAnalyzer -Path . -Recurse -ExcludeRule PSAvoidUsingWriteHost

bom-check:
    pwsh -File scripts/Apply-Bom.ps1 -Check

# ---------------------------------------------------------------------------
# 📝 Apply UTF-8 BOM to every .ps1 / .psm1 / .psd1 / .md
# ---------------------------------------------------------------------------
bom:
    pwsh -File scripts/Apply-Bom.ps1

# ---------------------------------------------------------------------------
# 🔖 Bump CalVer (YY.DOY.patch)
# ---------------------------------------------------------------------------
bump:
    pwsh -File scripts/Bump-Version.ps1

# ---------------------------------------------------------------------------
# 📦 Build distributable zip in dist/
# ---------------------------------------------------------------------------
package: bom
    @if (-not (Test-Path {{dist_dir}})) { New-Item -ItemType Directory {{dist_dir}} | Out-Null }
    $manifest = Import-PowerShellDataFile {{manifest_path}}
    $version  = $manifest.ModuleVersion
    $zip      = "{{dist_dir}}/{{module_name}}-$version.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    $files = @( \
        '{{manifest_path}}', \
        '{{module_name}}.psm1', \
        'README.md', 'LICENSE', 'CHANGELOG.md', 'profile-snippet.ps1', \
        'Private', 'Public' \
    )
    Compress-Archive -Path $files -DestinationPath $zip -Force
    Write-Host "Packaged: $zip"

# ---------------------------------------------------------------------------
# 🔏 Sign all .ps1 / .psm1 / .psd1 with EV cert (requires thumbprint in .env)
# ---------------------------------------------------------------------------
sign:
    @if (-not $env:CODE_SIGNING_CERTIFICATE_THUMBPRINT) { \
        Write-Warning 'CODE_SIGNING_CERTIFICATE_THUMBPRINT not set; skipping signing.'; \
        exit 0 \
    }
    $cert = Get-ChildItem Cert:\CurrentUser\My | \
        Where-Object Thumbprint -eq $env:CODE_SIGNING_CERTIFICATE_THUMBPRINT | \
        Select-Object -First 1
    if (-not $cert) { throw 'Signing certificate not found in Cert:\CurrentUser\My' }
    Get-ChildItem -Recurse -Include *.ps1, *.psm1, *.psd1 -File | \
        Where-Object FullName -notlike '*\dist\*' | \
        Where-Object FullName -notlike '*\tests\*' | \
        ForEach-Object { \
            Set-AuthenticodeSignature -FilePath $_.FullName -Certificate $cert \
                -TimestampServer 'http://timestamp.digicert.com' | Out-Null; \
            Write-Host "Signed: $($_.Name)" \
        }

# ---------------------------------------------------------------------------
# 🚀 Release: lint → test → package → sign
# ---------------------------------------------------------------------------
release: lint test package sign
    Write-Host "Release build complete."

# ---------------------------------------------------------------------------
# 📤 Publish to PSGallery (requires PSGALLERY_API_KEY in .env)
# ---------------------------------------------------------------------------
publish: release
    @if (-not $env:PSGALLERY_API_KEY) { throw 'PSGALLERY_API_KEY not set' }
    Publish-Module -Path . -NuGetApiKey $env:PSGALLERY_API_KEY -Verbose
    Write-Host "Published to PSGallery."

# ---------------------------------------------------------------------------
# 🏠 Install the local build into the current user's module path
# ---------------------------------------------------------------------------
install: package
    $manifest = Import-PowerShellDataFile {{manifest_path}}
    $version  = $manifest.ModuleVersion
    $target   = if ($env:MODULE_INSTALL_PATH) { $env:MODULE_INSTALL_PATH } \
                else { "$env:ProgramFiles\WindowsPowerShell\Modules" }
    $dest     = Join-Path $target '{{module_name}}' $version
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item "{{dist_dir}}/{{module_name}}-$version.zip" /tmp/mod.zip -Force
    Expand-Archive -Path /tmp/mod.zip -DestinationPath $dest -Force
    Write-Host "Installed to: $dest"

# ---------------------------------------------------------------------------
# 🧹 Clean build artifacts
# ---------------------------------------------------------------------------
clean:
    if (Test-Path {{dist_dir}}) { Remove-Item {{dist_dir}} -Recurse -Force }
    Get-ChildItem -Recurse -Include *.bak, TestResults, coverage.xml -Force | \
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Clean."
