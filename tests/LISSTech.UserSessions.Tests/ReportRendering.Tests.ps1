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
    $ProjectRoot  = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
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
            $script:html | Should -Match '--bg:\s*#f5f1e8'
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
# Markdown renderer composition
# =============================================================================

Describe 'Markdown report composition' {

    Context 'Given a minimal scan' {
        BeforeAll {
            $sessions = @((New-FakeSession -Username 'alice'))
            $scan     = New-FakeScanResult -Scanned 1 -Sessions $sessions

            $script:md = & (Get-Module LISSTech.UserSessions) {
                param($scan, $sessions)
                $ctx = New-ReportContext -ScanResult $scan -FilteredSessions $sessions -ScopeInfo @{}
                Format-ReportMarkdown -Context $ctx
            } $scan $sessions
        }

        It 'Then output begins with an H1 report heading' {
            $script:md | Should -Match '^# Session Report'
        }

        It 'Then a Summary section is present' {
            $script:md | Should -Match '## Summary'
        }

        It 'Then a per-server section is present' {
            $script:md | Should -Match '## Sessions by server'
        }
    }
}

# =============================================================================
# Clipboard + file path decisions — pure functions, unit-testable
# =============================================================================

Describe 'Resolve-ReportClipboardDecision' {

    Context 'Given format=markdown and no -ReportPath' {
        It 'Then the default decision is to copy' {
            & (Get-Module LISSTech.UserSessions) {
                Resolve-ReportClipboardDecision -Format 'markdown' -ClipboardExplicit $false -ClipboardOn $false -HasReportPath $false
            } | Should -BeTrue
        }
    }

    Context 'Given format=markdown with -ReportPath set' {
        It 'Then the default decision is NOT to copy' {
            & (Get-Module LISSTech.UserSessions) {
                Resolve-ReportClipboardDecision -Format 'markdown' -ClipboardExplicit $false -ClipboardOn $false -HasReportPath $true
            } | Should -BeFalse
        }
    }

    Context 'Given format=html and no -ReportPath' {
        It 'Then the default decision is to copy (CF_HTML paste)' {
            & (Get-Module LISSTech.UserSessions) {
                Resolve-ReportClipboardDecision -Format 'html' -ClipboardExplicit $false -ClipboardOn $false -HasReportPath $false
            } | Should -BeTrue
        }
    }

    Context 'Given format=html with -ReportPath (silent attachment mode)' {
        It 'Then clipboard is not touched by default' {
            & (Get-Module LISSTech.UserSessions) {
                Resolve-ReportClipboardDecision -Format 'html' -ClipboardExplicit $false -ClipboardOn $false -HasReportPath $true
            } | Should -BeFalse
        }
    }

    Context 'Given -Clipboard:$false explicitly passed' {
        It 'Then clipboard is suppressed regardless of defaults' {
            & (Get-Module LISSTech.UserSessions) {
                Resolve-ReportClipboardDecision -Format 'html' -ClipboardExplicit $true -ClipboardOn $false -HasReportPath $false
            } | Should -BeFalse
        }
    }
}

Describe 'Resolve-ReportFilePath' {

    Context 'Given format=markdown without -ReportPath' {
        It 'Then no file path is produced (clipboard-only)' {
            & (Get-Module LISSTech.UserSessions) {
                Resolve-ReportFilePath -Format 'markdown'
            } | Should -BeNullOrEmpty
        }
    }

    Context 'Given format=html without -ReportPath' {
        It 'Then a temp file path is produced' {
            $path = & (Get-Module LISSTech.UserSessions) {
                Resolve-ReportFilePath -Format 'html'
            }
            $path | Should -Match '\.html$'
            $path | Should -Match 'UserSession-Report'
        }
    }

    Context 'Given -ReportPath is provided' {
        It 'Then that exact path is returned regardless of format' {
            & (Get-Module LISSTech.UserSessions) {
                Resolve-ReportFilePath -Format 'markdown' -ReportPath 'C:\tmp\my.md'
            } | Should -Be 'C:\tmp\my.md'
        }
    }
}

AfterAll {
    Remove-Module LISSTech.UserSessions -Force -ErrorAction SilentlyContinue
}
