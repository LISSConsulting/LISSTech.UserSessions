<#
    Pester 5.x — behavior-driven tests for the reporting subsystem.

    We treat each Describe block as a behavior of the system, each
    Context as a scenario, and each It as an assertion about that
    scenario. This is BDD without the Gherkin theatre — the
    `Given → When → Then` structure lives in the Context/It names,
    which is how Pester 5 idiomatically expresses it.

    Tests run without touching the filesystem or the real clipboard —
    we construct ReportContexts directly from synthetic inputs.
#>

BeforeAll {
    $ProjectRoot = $PSScriptRoot
    while ($ProjectRoot -and -not (Test-Path (Join-Path $ProjectRoot 'LISSTech.UserSessions.psd1'))) {
        $ProjectRoot = Split-Path -Parent $ProjectRoot
    }
    if (-not $ProjectRoot) { throw 'Unable to locate LISSTech.UserSessions.psd1 from test directory' }
    $ManifestPath = Join-Path $ProjectRoot 'LISSTech.UserSessions.psd1'
    Import-Module $ManifestPath -Force

    # -- Synthetic session factory --------------------------------------
    # One place defining what a "session under test" looks like, so
    # individual tests stay short and readable.
    function New-FakeSession {
        param(
            [string]$Server       = 'TEST-SRV1',
            [int]$SessionId       = 42,
            [string]$Username     = 'testuser',
            [string]$Domain       = 'TEST',
            [string]$WinStation   = 'RDP-Tcp#1',
            $State                = [LISSTech.Wts.WtsConnectState]::Active,
            [datetime]$LogonTime  = (Get-Date).AddHours(-2),
            [datetime]$LastInputTime = (Get-Date).AddMinutes(-10),
            [TimeSpan]$IdleTime   = (New-TimeSpan -Minutes 10),
            [bool]$IsCurrent      = $false,
            [bool]$IsUserDisabled = $false
        )
        [pscustomobject]@{
            PSTypeName    = 'LISSTech.UserSessions.Session'
            Server        = $Server
            SessionId     = $SessionId
            Username      = $Username
            Domain        = $Domain
            WinStation    = $WinStation
            State         = $State
            LogonTime     = $LogonTime
            LastInputTime = $LastInputTime
            IdleTime      = $IdleTime
            IsCurrent     = $IsCurrent
            IsUserDisabled = $IsUserDisabled
        }
    }

    function New-FakeScanResult {
        param(
            [int]$Scanned = 1,
            [object[]]$Sessions = @(),
            [object[]]$Offline = @(),
            [object[]]$Errored = @(),
            [TimeSpan]$Elapsed = (New-TimeSpan -Seconds 3)
        )
        [pscustomobject]@{
            Users    = 0
            Scanned  = $Scanned
            Sessions = $Sessions
            Offline  = $Offline
            Errored  = $Errored
            Elapsed  = $Elapsed
        }
    }

    # ---- InModuleScope wrapper so we can reach private functions ----
    # These helpers let the tests call private functions without breaking
    # the module's encapsulation for production consumers.
    function Invoke-PrivateFunction {
        param([string]$Name, [hashtable]$Arguments = @{})
        & (Get-Module LISSTech.UserSessions) $Name @Arguments
    }
}

# =============================================================================
# View model — the domain language of reporting
# =============================================================================

Describe 'ReportContext construction' {

    Context 'Given a scan with two active sessions on one server' {
        BeforeAll {
            $sessions = @(
                (New-FakeSession -Username 'alice' -SessionId 1)
                (New-FakeSession -Username 'bob'   -SessionId 2)
            )
            $scan = New-FakeScanResult -Scanned 1 -Sessions $sessions

            $script:ctx = & (Get-Module LISSTech.UserSessions) {
                param($scan, $sessions)
                New-ReportContext -ScanResult $scan -FilteredSessions $sessions -ScopeInfo @{}
            } $scan $sessions
        }

        It 'Then the summary reports 2 total sessions' {
            $script:ctx.Summary.Total | Should -Be 2
        }

        It 'Then the summary reports 2 active sessions' {
            $script:ctx.Summary.Active | Should -Be 2
        }

        It 'Then the summary reports 2 unique users' {
            $script:ctx.Summary.UniqueUsers | Should -Be 2
        }

        It 'Then a single ServerGroup is produced' {
            $script:ctx.ServerGroups.Count | Should -Be 1
        }

        It 'Then the scope description marks as default' {
            $script:ctx.Scope.IsDefault | Should -BeTrue
        }
    }

    Context 'Given a session for a disabled user' {
        BeforeAll {
            $sessions = @(
                (New-FakeSession -Username 'ghost' -IsUserDisabled $true)
            )
            $scan = New-FakeScanResult -Scanned 1 -Sessions $sessions

            $script:ctx = & (Get-Module LISSTech.UserSessions) {
                param($scan, $sessions)
                New-ReportContext -ScanResult $scan -FilteredSessions $sessions -ScopeInfo @{}
            } $scan $sessions
        }

        It 'Then DisabledSessions contains that session' {
            $script:ctx.DisabledSessions.Count         | Should -Be 1
            $script:ctx.DisabledSessions[0].Username   | Should -Be 'ghost'
        }

        It 'Then the summary disabled count is 1' {
            $script:ctx.Summary.Disabled | Should -Be 1
        }
    }

    Context 'Given errored hosts clustered by message' {
        BeforeAll {
            $errored = @(
                [pscustomobject]@{ Server = 'HOSTA'; Error = 'RPC unavailable' }
                [pscustomobject]@{ Server = 'HOSTB'; Error = 'RPC unavailable' }
                [pscustomobject]@{ Server = 'HOSTC'; Error = 'Access denied' }
            )
            $scan = New-FakeScanResult -Scanned 3 -Errored $errored

            $script:ctx = & (Get-Module LISSTech.UserSessions) {
                param($scan)
                New-ReportContext -ScanResult $scan -FilteredSessions @() -ScopeInfo @{}
            } $scan
        }

        It 'Then errored hosts are grouped by message' {
            $script:ctx.ErroredGroups.Count | Should -Be 2
        }

        It 'Then the largest group appears first (sorted by count desc)' {
            $script:ctx.ErroredGroups[0].Message | Should -Be 'RPC unavailable'
            $script:ctx.ErroredGroups[0].Count   | Should -Be 2
        }
    }
}

# =============================================================================
# HTML renderer composition
# =============================================================================

Describe 'HTML report composition' {

    Context 'Given a minimal scan with one active session' {
        BeforeAll {
            $sessions = @((New-FakeSession -Username 'alice'))
            $scan     = New-FakeScanResult -Scanned 1 -Sessions $sessions

            $script:html = & (Get-Module LISSTech.UserSessions) {
                param($scan, $sessions)
                $ctx = New-ReportContext -ScanResult $scan -FilteredSessions $sessions -ScopeInfo @{}
                Format-ReportHtml -Context $ctx
            } $scan $sessions
        }

        It 'Then the output is a complete HTML document' {
            $script:html | Should -Match '^<!DOCTYPE html>'
            $script:html | Should -Match '</html>\s*$'
        }

        It 'Then the banner section is present' {
            $script:html | Should -Match 'class="banner"'
        }

        It 'Then the inline <style> block is present exactly once' {
            ([regex]::Matches($script:html, '<style>')).Count | Should -Be 1
        }

        It 'Then the CSS custom properties are defined' {
            $script:html | Should -Match '--bg:\s*#[0-9a-fA-F]{3,6}'
            $script:html | Should -Match '--card:\s*#[0-9a-fA-F]{3,6}'
            $script:html | Should -Match '--ink:\s*#[0-9a-fA-F]{3,6}'
        }

        It 'Then the session username appears in the rendered HTML' {
            $script:html | Should -Match 'alice'
        }
    }

    Context 'Given a scan with no disabled users' {
        BeforeAll {
            $sessions = @((New-FakeSession))
            $scan     = New-FakeScanResult -Scanned 1 -Sessions $sessions

            $script:html = & (Get-Module LISSTech.UserSessions) {
                param($scan, $sessions)
                $ctx = New-ReportContext -ScanResult $scan -FilteredSessions $sessions -ScopeInfo @{}
                Format-ReportHtml -Context $ctx
            } $scan $sessions
        }

        It 'Then the disabled-users section is omitted' {
            $script:html | Should -Not -Match 'Disabled users'
        }
    }

    Context 'Given a scan with a disabled user' {
        BeforeAll {
            $sessions = @((New-FakeSession -Username 'ghost' -IsUserDisabled $true))
            $scan     = New-FakeScanResult -Scanned 1 -Sessions $sessions

            $script:html = & (Get-Module LISSTech.UserSessions) {
                param($scan, $sessions)
                $ctx = New-ReportContext -ScanResult $scan -FilteredSessions $sessions -ScopeInfo @{}
                Format-ReportHtml -Context $ctx
            } $scan $sessions
        }

        It 'Then the disabled-users section is rendered' {
            $script:html | Should -Match 'Disabled users'
        }

        It 'Then the disabled badge is applied to the user' {
            $script:html | Should -Match 'disabled-badge'
        }
    }

    Context 'Given a logoff result with 3 successes and 1 failure' {
        BeforeAll {
            $logoff = [pscustomobject]@{
                Succeeded = 3
                Failed    = 1
                Skipped   = 0
                Failures  = @([pscustomobject]@{
                    Server    = 'SRV1'
                    Username  = 'alice'
                    SessionId = 1
                    Error     = 'RPC_S_SERVER_UNAVAILABLE'
                })
            }
            $sessions = @((New-FakeSession))
            $scan     = New-FakeScanResult -Scanned 1 -Sessions $sessions

            $script:html = & (Get-Module LISSTech.UserSessions) {
                param($scan, $sessions, $logoff)
                $ctx = New-ReportContext -ScanResult $scan -FilteredSessions $sessions -LogoffResult $logoff -ScopeInfo @{}
                Format-ReportHtml -Context $ctx
            } $scan $sessions $logoff
        }

        It 'Then the logoff banner is rendered as "mixed"' {
            $script:html | Should -Match 'class="logoff mixed"'
        }

        It 'Then the failure table lists the failing user' {
            $script:html | Should -Match 'RPC_S_SERVER_UNAVAILABLE'
        }
    }
}

# =============================================================================
# Clipboard + file path decisions — pure functions, unit-testable
# =============================================================================

Describe 'Resolve-ReportClipboardDecision' {

    Context 'Given no -ReportPath' {
        It 'Then the default decision is to copy (CF_HTML paste)' {
            & (Get-Module LISSTech.UserSessions) {
                Resolve-ReportClipboardDecision -ClipboardExplicit $false -ClipboardOn $false -HasReportPath $false
            } | Should -BeTrue
        }
    }

    Context 'Given -ReportPath set (silent attachment mode)' {
        It 'Then clipboard is not touched by default' {
            & (Get-Module LISSTech.UserSessions) {
                Resolve-ReportClipboardDecision -ClipboardExplicit $false -ClipboardOn $false -HasReportPath $true
            } | Should -BeFalse
        }
    }

    Context 'Given -Clipboard:$false explicitly passed' {
        It 'Then clipboard is suppressed regardless of defaults' {
            & (Get-Module LISSTech.UserSessions) {
                Resolve-ReportClipboardDecision -ClipboardExplicit $true -ClipboardOn $false -HasReportPath $false
            } | Should -BeFalse
        }
    }

    Context 'Given -Clipboard explicitly with -ReportPath' {
        It 'Then clipboard is forced on alongside the file' {
            & (Get-Module LISSTech.UserSessions) {
                Resolve-ReportClipboardDecision -ClipboardExplicit $true -ClipboardOn $true -HasReportPath $true
            } | Should -BeTrue
        }
    }
}

Describe 'Resolve-ReportFilePath' {

    Context 'Given no -ReportPath' {
        It 'Then a temp file path is produced (so the browser preview has somewhere to open)' {
            $path = & (Get-Module LISSTech.UserSessions) { Resolve-ReportFilePath }
            $path | Should -Match '\.html$'
            $path | Should -Match 'UserSession-Report'
        }
    }

    Context 'Given -ReportPath is provided' {
        It 'Then that exact path is returned verbatim' {
            & (Get-Module LISSTech.UserSessions) {
                Resolve-ReportFilePath -ReportPath 'C:\tmp\my.html'
            } | Should -Be 'C:\tmp\my.html'
        }
    }
}

Describe 'Get-LocalHostAliasSet' {

    It 'Includes MachineName' {
        $set = & (Get-Module LISSTech.UserSessions) { Get-LocalHostAliasSet }
        $set.Contains([Environment]::MachineName) | Should -BeTrue
    }

    It 'Includes localhost' {
        $set = & (Get-Module LISSTech.UserSessions) { Get-LocalHostAliasSet }
        $set.Contains('localhost') | Should -BeTrue
    }

    It 'Includes 127.0.0.1' {
        $set = & (Get-Module LISSTech.UserSessions) { Get-LocalHostAliasSet }
        $set.Contains('127.0.0.1') | Should -BeTrue
    }

    It 'Includes ::1' {
        $set = & (Get-Module LISSTech.UserSessions) { Get-LocalHostAliasSet }
        $set.Contains('::1') | Should -BeTrue
    }

    It 'Is case-insensitive for LoCaLhOsT' {
        $set = & (Get-Module LISSTech.UserSessions) { Get-LocalHostAliasSet }
        $set.Contains('LoCaLhOsT') | Should -BeTrue
    }
}

Describe 'ConvertTo-CfHtml (CF_HTML header construction)' {

    BeforeAll {
        $script:Wrap = { param($h)
            & (Get-Module LISSTech.UserSessions) { param($x) ConvertTo-CfHtml -Html $x } $h
        }
    }

    It 'emits the Version:0.9 marker' {
        $out = & $script:Wrap '<p>x</p>'
        $out | Should -Match 'Version:0\.9'
    }

    It 'wraps the payload in StartFragment / EndFragment markers' {
        $out = & $script:Wrap '<p>hello</p>'
        $out | Should -Match '<!--StartFragment-->\s*<p>hello</p>\s*<!--EndFragment-->'
    }

    It 'StartFragment / EndFragment offsets bound the payload bytes exactly' {
        $payload = '<p>fragment-body</p>'
        $out = & $script:Wrap $payload
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($out)

        # Parse offsets from the header.
        if ($out -notmatch 'StartFragment:(\d{10})') { throw 'StartFragment header missing' }
        $startFragment = [int]$Matches[1]
        if ($out -notmatch 'EndFragment:(\d{10})')   { throw 'EndFragment header missing'   }
        $endFragment = [int]$Matches[1]

        # Bytes between the offsets must be the original payload, exactly.
        $sliceLen = $endFragment - $startFragment
        $slice    = [System.Text.Encoding]::UTF8.GetString($bytes, $startFragment, $sliceLen)
        $slice | Should -Be $payload
    }

    It 'StartHTML offset points at the start of the HTML shell' {
        $payload = '<p>x</p>'
        $out = & $script:Wrap $payload
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($out)

        if ($out -notmatch 'StartHTML:(\d{10})') { throw 'StartHTML header missing' }
        $startHtml = [int]$Matches[1]
        # Bytes from StartHTML forward should begin with "<html" — this is
        # the CF_HTML shell, not the fragment itself.
        $probeLen = [System.Text.Encoding]::UTF8.GetByteCount('<html')
        $sliced = [System.Text.Encoding]::UTF8.GetString($bytes, $startHtml, $probeLen)
        $sliced | Should -Be '<html'
    }

    It 'handles multibyte UTF-8 payloads (offsets are byte counts, not char counts)' {
        $payload = '<p>café — naïve ☕</p>'
        $out = & $script:Wrap $payload
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($out)

        if ($out -notmatch 'StartFragment:(\d{10})') { throw 'StartFragment header missing' }
        $startFragment = [int]$Matches[1]
        if ($out -notmatch 'EndFragment:(\d{10})')   { throw 'EndFragment header missing'   }
        $endFragment = [int]$Matches[1]

        $slice = [System.Text.Encoding]::UTF8.GetString($bytes, $startFragment, $endFragment - $startFragment)
        $slice | Should -Be $payload
    }

    It 'Lifts head <style> blocks into the fragment so pasted styles survive' {
        # The fragment is the only thing rich-text editors (HaloPSA, Outlook,
        # TinyMCE, Word) read. <style> in <head> would otherwise be dropped on
        # paste, leaving the report unstyled.
        $doc = @'
<!DOCTYPE html>
<html><head><style>.banner { background: red }</style></head>
<body><p>payload</p></body></html>
'@
        $out = & $script:Wrap $doc
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($out)

        if ($out -notmatch 'StartFragment:(\d{10})') { throw 'StartFragment header missing' }
        $startFragment = [int]$Matches[1]
        if ($out -notmatch 'EndFragment:(\d{10})')   { throw 'EndFragment header missing' }
        $endFragment = [int]$Matches[1]

        $slice = [System.Text.Encoding]::UTF8.GetString($bytes, $startFragment, $endFragment - $startFragment)
        $slice | Should -Match '<style[^>]*>\s*\.banner \{ background: red \}\s*</style\s*>'
        $slice | Should -Match '<p>payload</p>'
    }

    It 'Fragment does NOT contain the HTML shell tags (paste targets reject fragments that wrap DOCTYPE/html/head)' {
        # Full document input — markers must go INSIDE <body>, not wrap the shell.
        $doc = @'
<!DOCTYPE html>
<html lang="en">
<head><title>t</title></head>
<body><p>payload</p></body>
</html>
'@
        $out = & $script:Wrap $doc
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($out)

        if ($out -notmatch 'StartFragment:(\d{10})') { throw 'StartFragment header missing' }
        $startFragment = [int]$Matches[1]
        if ($out -notmatch 'EndFragment:(\d{10})')   { throw 'EndFragment header missing'   }
        $endFragment = [int]$Matches[1]

        $slice = [System.Text.Encoding]::UTF8.GetString($bytes, $startFragment, $endFragment - $startFragment)
        $slice | Should -Not -Match '<!DOCTYPE'
        $slice | Should -Not -Match '<html'
        $slice | Should -Not -Match '<head'
        $slice | Should -Not -Match '</body'
        $slice | Should -Match '<p>payload</p>'
    }
}

Describe 'Set-ClipboardHtml (PS7 MTA path)' {

    # -Skip: is evaluated at Pester discovery (before BeforeAll), so environment
    # probes that depend on the imported module type don't work there. Use
    # Set-ItResult -Skipped at runtime instead.

    It 'ClipboardBridge type loaded at module import' {
        if (-not ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop')) {
            Set-ItResult -Skipped -Because 'not Windows — bridge is Windows-only'
            return
        }
        'LISSTech.UserSessions.ClipboardBridge' -as [type] | Should -Not -BeNullOrEmpty
    }

    It 'succeeds on MTA apartment via ClipboardBridge' {
        if (-not ('LISSTech.UserSessions.ClipboardBridge' -as [type])) {
            Set-ItResult -Skipped -Because 'ClipboardBridge unavailable (pwsh without Microsoft.WindowsDesktop.App)'
            return
        }
        # On PS7 the default apartment is MTA — the bridge is the only way this succeeds.
        { & (Get-Module LISSTech.UserSessions) {
            param($h) Set-ClipboardHtml -Html $h
        } '<b>test</b>' } | Should -Not -Throw
    }
}

Describe 'Get-SortedSessionsForDisplay (HTML report ordering)' {

    It 'orders active-first, idle desc, username asc' {
        # Hand-computed expected ordering:
        #   alice: Active, idle 30m       (Active, largest idle)
        #   bob:   Active, idle 5m        (Active, smaller idle)
        #   carol: Disconnected, idle 60m (Non-active, larger idle)
        #   dave:  Disconnected, idle 10m (Non-active, smaller idle)
        #   eve:   Active, idle 5m, eve < bob alphabetically within the same active+idle bucket
        # Actually: active-first is primary key, then idle desc, then username asc.
        # So within Active+idle=5m, 'bob' < 'eve'.
        $sessions = @(
            (New-FakeSession -Username 'eve'   -State ([LISSTech.Wts.WtsConnectState]::Active)       -IdleTime (New-TimeSpan -Minutes 5))
            (New-FakeSession -Username 'bob'   -State ([LISSTech.Wts.WtsConnectState]::Active)       -IdleTime (New-TimeSpan -Minutes 5))
            (New-FakeSession -Username 'alice' -State ([LISSTech.Wts.WtsConnectState]::Active)       -IdleTime (New-TimeSpan -Minutes 30))
            (New-FakeSession -Username 'carol' -State ([LISSTech.Wts.WtsConnectState]::Disconnected) -IdleTime (New-TimeSpan -Minutes 60))
            (New-FakeSession -Username 'dave'  -State ([LISSTech.Wts.WtsConnectState]::Disconnected) -IdleTime (New-TimeSpan -Minutes 10))
        )
        $sorted = & (Get-Module LISSTech.UserSessions) {
            param($s) Get-SortedSessionsForDisplay -Sessions $s
        } $sessions

        $sorted.Username | Should -Be @('alice', 'bob', 'eve', 'carol', 'dave')
    }
}

AfterAll {
    Remove-Module LISSTech.UserSessions -Force -ErrorAction SilentlyContinue
}
