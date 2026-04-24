<#
    Pester 5.x tests for LISSTech.UserSessions.

    These tests focus on parsing correctness, API surface, and error
    handling. Live WTS / AD calls require Windows + domain access and
    are skipped when run outside that environment.

    Run: Invoke-Pester -Path tests/ -Output Detailed
#>

BeforeAll {
    $ProjectRoot = $PSScriptRoot
    while ($ProjectRoot -and -not (Test-Path (Join-Path $ProjectRoot 'LISSTech.UserSessions.psd1'))) {
        $ProjectRoot = Split-Path -Parent $ProjectRoot
    }
    if (-not $ProjectRoot) { throw 'Unable to locate LISSTech.UserSessions.psd1 from test directory' }
    $ManifestPath = Join-Path $ProjectRoot 'LISSTech.UserSessions.psd1'
    Import-Module $ManifestPath -Force
}

Describe 'Module manifest' {

    It 'has a valid manifest that parses' {
        $manifest = Test-ModuleManifest -Path $ManifestPath -ErrorAction Stop
        $manifest | Should -Not -BeNullOrEmpty
    }

    It 'exports the three expected public cmdlets' {
        $exported = Get-Command -Module LISSTech.UserSessions
        $exported.Name | Should -Contain 'Find-UserSession'
        $exported.Name | Should -Contain 'Show-UserSession'
        $exported.Name | Should -Contain 'Stop-UserSession'
    }

    It 'uses CalVer (YY.DOY.patch) for ModuleVersion' {
        $manifest = Import-PowerShellDataFile $ManifestPath
        $manifest.ModuleVersion | Should -Match '^\d{2}\.\d{1,3}\.\d+$'
    }

    It 'has no RequiredModules (zero external dependencies)' {
        $manifest = Import-PowerShellDataFile $ManifestPath
        $manifest.RequiredModules | Should -BeNullOrEmpty
    }
}

Describe 'BOM compliance' {

    It 'every source file has UTF-8 BOM' {
        $files = Get-ChildItem $ProjectRoot -Recurse -File -Include *.ps1, *.psm1, *.psd1, *.md |
            Where-Object FullName -notlike '*\dist\*'

        $missing = foreach ($f in $files) {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)[0..2]
            if (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
                $f.FullName
            }
        }

        $missing | Should -BeNullOrEmpty
    }
}

Describe 'Parser hazards' {

    It 'has no $var: drive-reference hazards in double-quoted strings' {
        $offenders = Get-ChildItem $ProjectRoot -Recurse -File -Include *.ps1, *.psm1 |
            Where-Object FullName -notlike '*\dist\*' |
            ForEach-Object {
                $lines = Get-Content $_.FullName
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    $line = $lines[$i]
                    # Strict pattern: $identifier followed by colon inside a double-quoted
                    # string, excluding legitimate $script:, $env:, etc. scope refs.
                    if ($line -match '"[^"]*\$[A-Za-z_][A-Za-z0-9_]*:' -and
                        $line -notmatch '\$(script|env|global|local|using|private):' -and
                        $line -notmatch '\$\{') {
                        [pscustomobject]@{ File = $_.Name; Line = $i + 1; Text = $line.Trim() }
                    }
                }
            }

        $offenders | Should -BeNullOrEmpty
    }

    It 'has no bare scriptblock switch conditions' {
        $offenders = Get-ChildItem $ProjectRoot -Recurse -File -Include *.ps1 |
            Where-Object FullName -notlike '*\dist\*' |
            ForEach-Object {
                Select-String -Path $_.FullName -Pattern '^\s*\{[^}]+\}\s+\{'
            }
        $offenders | Should -BeNullOrEmpty
    }

    It 'has no return switch patterns' {
        $offenders = Get-ChildItem $ProjectRoot -Recurse -File -Include *.ps1, *.psm1 |
            Where-Object FullName -notlike '*\dist\*' |
            ForEach-Object {
                Select-String -Path $_.FullName -Pattern 'return\s+switch\b'
            }
        $offenders | Should -BeNullOrEmpty
    }

    It 'has no backtick line continuations' {
        $offenders = Get-ChildItem $ProjectRoot -Recurse -File -Include *.ps1, *.psm1 |
            Where-Object FullName -notlike '*\dist\*' |
            ForEach-Object {
                $lines = Get-Content $_.FullName
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    # A literal backtick at end of line
                    if ($lines[$i] -match '`$') {
                        [pscustomobject]@{ File = $_.Name; Line = $i + 1 }
                    }
                }
            }
        $offenders | Should -BeNullOrEmpty
    }
}

Describe 'Find-UserSession parameters' {

    It 'has -ComputerName with Server and Name aliases' {
        $param = (Get-Command Find-UserSession).Parameters['ComputerName']
        $param | Should -Not -BeNullOrEmpty
        $param.Aliases | Should -Contain 'Server'
        $param.Aliases | Should -Contain 'Name'
    }

    It 'has -ComputerLdapFilter with ServerLdapFilter alias' {
        $param = (Get-Command Find-UserSession).Parameters['ComputerLdapFilter']
        $param | Should -Not -BeNullOrEmpty
        $param.Aliases | Should -Contain 'ServerLdapFilter'
    }
}

Describe 'Show-UserSession parameters' {

    It 'accepts -Report markdown|html' {
        $param = (Get-Command Show-UserSession).Parameters['Report']
        $param | Should -Not -BeNullOrEmpty
        $validValues = $param.Attributes.Where({ $_ -is [ValidateSet] }).ValidValues
        $validValues | Should -Contain 'markdown'
        $validValues | Should -Contain 'html'
    }

    It 'has -ReportPath and -Clipboard' {
        $params = (Get-Command Show-UserSession).Parameters
        $params['ReportPath'] | Should -Not -BeNullOrEmpty
        $params['Clipboard']  | Should -Not -BeNullOrEmpty
    }

    It 'supports ShouldProcess with ConfirmImpact=High' {
        $cmd = Get-Command Show-UserSession
        $attr = $cmd.ScriptBlock.Attributes.Where({ $_ -is [CmdletBindingAttribute] })[0]
        $attr.SupportsShouldProcess | Should -BeTrue
        $attr.ConfirmImpact         | Should -Be 'High'
    }
}

Describe 'Stop-UserSession parameters' {

    It 'has -ComputerName as primary with Server alias' {
        $param = (Get-Command Stop-UserSession).Parameters['ComputerName']
        $param | Should -Not -BeNullOrEmpty
        $param.Aliases | Should -Contain 'Server'
    }

    It 'supports ShouldProcess with ConfirmImpact=High' {
        $cmd = Get-Command Stop-UserSession
        $attr = $cmd.ScriptBlock.Attributes.Where({ $_ -is [CmdletBindingAttribute] })[0]
        $attr.SupportsShouldProcess | Should -BeTrue
        $attr.ConfirmImpact         | Should -Be 'High'
    }
}

AfterAll {
    Remove-Module LISSTech.UserSessions -Force -ErrorAction SilentlyContinue
}
