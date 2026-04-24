<#
    Pester 5.x tests for the FleetGrid renderer seams.

    Focuses on the pure decision layers — bucket assignment, sort order,
    width breakpoint selection, and NOTE cell content. The actual
    terminal-write calls in Write-FleetGrid / Write-FleetSummaryStrip
    are exercised by the visual smoke test, not unit tests.

    Run: Invoke-Pester -Path tests/
#>

BeforeAll {
    $ProjectRoot = $PSScriptRoot
    while ($ProjectRoot -and -not (Test-Path (Join-Path $ProjectRoot 'LISSTech.UserSessions.psd1'))) {
        $ProjectRoot = Split-Path -Parent $ProjectRoot
    }
    if (-not $ProjectRoot) { throw 'Unable to locate LISSTech.UserSessions.psd1 from test directory' }
    $ManifestPath = Join-Path $ProjectRoot 'LISSTech.UserSessions.psd1'
    Import-Module $ManifestPath -Force

    function New-FleetSession {
        param(
            [string]$Server       = 'RDS-01',
            [string]$Username     = 'alice',
            $State                = [LISSTech.Wts.WtsConnectState]::Active,
            [TimeSpan]$IdleTime   = (New-TimeSpan -Minutes 10),
            [bool]$IsCurrent      = $false,
            [bool]$IsUserDisabled = $false,
            [int]$SessionId       = 1,
            [string]$WinStation   = 'RDP-Tcp#1'
        )
        [pscustomobject]@{
            Server = $Server; Username = $Username; State = $State
            IdleTime = $IdleTime; IsCurrent = $IsCurrent; IsUserDisabled = $IsUserDisabled
            SessionId = $SessionId; WinStation = $WinStation
            LogonTime = (Get-Date).AddHours(-4); LastInputTime = (Get-Date); Domain = 'CORP'
        }
    }
}

Describe 'Get-FleetRowPriority' {

    Context 'Host-level synthetic rows' {
        It 'ERR outranks every other bucket' {
            $result = & (Get-Module LISSTech.UserSessions) { Get-FleetRowPriority -RowKind 'error' }
            $result.Bucket | Should -Be 'ERR'
            $result.Rank   | Should -Be 0
        }

        It 'OFF ranks second' {
            $result = & (Get-Module LISSTech.UserSessions) { Get-FleetRowPriority -RowKind 'offline' }
            $result.Bucket | Should -Be 'OFF'
            $result.Rank   | Should -Be 1
        }
    }

    Context 'Session buckets' {
        It 'Disabled user -> !!' {
            $s = New-FleetSession -IsUserDisabled $true
            $r = & (Get-Module LISSTech.UserSessions) { param($x) Get-FleetRowPriority -RowKind 'session' -Session $x } $s
            $r.Bucket | Should -Be '!!'
        }

        It 'Disconnected + idle >= 7 days -> ! (stale)' {
            $s = New-FleetSession -State ([LISSTech.Wts.WtsConnectState]::Disconnected) -IdleTime (New-TimeSpan -Days 8)
            $r = & (Get-Module LISSTech.UserSessions) { param($x) Get-FleetRowPriority -RowKind 'session' -Session $x } $s
            $r.Bucket | Should -Be '!'
        }

        It 'Disconnected + idle < 7 days is NOT stale' {
            $s = New-FleetSession -State ([LISSTech.Wts.WtsConnectState]::Disconnected) -IdleTime (New-TimeSpan -Days 6)
            $r = & (Get-Module LISSTech.UserSessions) { param($x) Get-FleetRowPriority -RowKind 'session' -Session $x } $s
            $r.Bucket | Should -Be ''
        }

        It 'Active + IsCurrent -> * (disabled still wins)' {
            $currentOnly = New-FleetSession -IsCurrent $true
            $r = & (Get-Module LISSTech.UserSessions) { param($x) Get-FleetRowPriority -RowKind 'session' -Session $x } $currentOnly
            $r.Bucket | Should -Be '*'

            # Disabled + current: disabled wins
            $both = New-FleetSession -IsCurrent $true -IsUserDisabled $true
            $r2 = & (Get-Module LISSTech.UserSessions) { param($x) Get-FleetRowPriority -RowKind 'session' -Session $x } $both
            $r2.Bucket | Should -Be '!!'
        }

        It 'Normal session -> blank' {
            $s = New-FleetSession
            $r = & (Get-Module LISSTech.UserSessions) { param($x) Get-FleetRowPriority -RowKind 'session' -Session $x } $s
            $r.Bucket | Should -Be ''
        }
    }
}

Describe 'Get-FleetOrderedRows' {

    Context 'Global ordering' {
        BeforeAll {
            $A = [LISSTech.Wts.WtsConnectState]::Active
            $D = [LISSTech.Wts.WtsConnectState]::Disconnected

            $sessions = @(
                (New-FleetSession -Server 'RDS-A' -Username 'norm'    -State $A -IdleTime (New-TimeSpan -Minutes 5))
                (New-FleetSession -Server 'RDS-A' -Username 'ghost'   -State $D -IdleTime (New-TimeSpan -Days 20) -IsUserDisabled $true)
                (New-FleetSession -Server 'RDS-B' -Username 'stale'   -State $D -IdleTime (New-TimeSpan -Days 14))
                (New-FleetSession -Server 'RDS-C' -Username 'me'      -State $A -IdleTime (New-TimeSpan -Minutes 2) -IsCurrent $true)
                (New-FleetSession -Server 'RDS-A' -Username 'recent'  -State $A -IdleTime (New-TimeSpan -Minutes 30))
            )
            $offline = @([pscustomobject]@{ Name = 'RDS-D' })
            $errored = @([pscustomobject]@{ Server = 'RDS-E'; Error = 'RPC unavailable' })

            $script:ordered = & (Get-Module LISSTech.UserSessions) {
                param($s, $o, $e) Get-FleetOrderedRows -Sessions $s -Offline $o -Errored $e
            } $sessions $offline $errored
        }

        It 'ERR appears first' {
            $script:ordered[0].Bucket | Should -Be 'ERR'
        }

        It 'OFF appears second' {
            $script:ordered[1].Bucket | Should -Be 'OFF'
        }

        It '!! (disabled) appears third' {
            $script:ordered[2].Bucket | Should -Be '!!'
        }

        It '! (stale) appears fourth' {
            $script:ordered[3].Bucket | Should -Be '!'
        }

        It '* (current) appears fifth' {
            $script:ordered[4].Bucket | Should -Be '*'
        }

        It 'Within blank bucket, higher idle comes first (active)' {
            # recent (30m) before norm (5m)
            $blanks = @($script:ordered | Where-Object Bucket -eq '')
            $blanks[0].Session.Username | Should -Be 'recent'
            $blanks[1].Session.Username | Should -Be 'norm'
        }
    }

    Context 'Active-before-Disconnected tiebreak within blank bucket' {
        It 'Places Active ahead of Disconnected when idle is tied' {
            $A = [LISSTech.Wts.WtsConnectState]::Active
            $D = [LISSTech.Wts.WtsConnectState]::Disconnected
            $tied = @(
                (New-FleetSession -Server 'R' -Username 'a-disc'   -State $D -IdleTime (New-TimeSpan -Minutes 5))
                (New-FleetSession -Server 'R' -Username 'b-active' -State $A -IdleTime (New-TimeSpan -Minutes 5))
            )
            $rows = & (Get-Module LISSTech.UserSessions) { param($s) Get-FleetOrderedRows -Sessions $s } $tied
            $rows[0].Session.Username | Should -Be 'b-active'
            $rows[1].Session.Username | Should -Be 'a-disc'
        }
    }
}

Describe 'Get-FleetColWidths' {

    It 'Returns 120 map at canonical width' {
        $w = & (Get-Module LISSTech.UserSessions) { Get-FleetColWidths -TerminalWidth 120 }
        $w.Keys | Should -Contain 'ACCOUNT'
        $w.Keys | Should -Contain 'NOTE'
        $w.PRI  | Should -Be 3
    }

    It 'Returns 80 map when terminal is narrow' {
        $w = & (Get-Module LISSTech.UserSessions) { Get-FleetColWidths -TerminalWidth 80 }
        $w.Keys | Should -Not -Contain 'LOGON'
        $w.Keys | Should -Not -Contain 'ACCOUNT'
        $w.Keys | Should -Not -Contain 'SESSION'
    }

    It 'Returns 100 map at 100 cols (SESSION returns, ACCOUNT still absent)' {
        $w = & (Get-Module LISSTech.UserSessions) { Get-FleetColWidths -TerminalWidth 100 }
        $w.Keys | Should -Contain 'SESSION'
        $w.Keys | Should -Contain 'LOGON'
        $w.Keys | Should -Not -Contain 'ACCOUNT'
    }

    It 'Returns 160 map at 160 cols (no DOMAIN yet)' {
        $w = & (Get-Module LISSTech.UserSessions) { Get-FleetColWidths -TerminalWidth 160 }
        $w.Keys | Should -Contain 'ACCOUNT'
        $w.Keys | Should -Not -Contain 'DOMAIN'
        $w.Keys | Should -Not -Contain 'LASTINPUT'
    }

    It 'Returns 200 map at >= 200 cols (DOMAIN + LASTINPUT)' {
        $w = & (Get-Module LISSTech.UserSessions) { Get-FleetColWidths -TerminalWidth 240 }
        $w.Keys | Should -Contain 'DOMAIN'
        $w.Keys | Should -Contain 'LASTINPUT'
    }

    It 'Picks the largest breakpoint that fits (159 -> 120, not 160)' {
        $w = & (Get-Module LISSTech.UserSessions) { Get-FleetColWidths -TerminalWidth 159 }
        # 160 breakpoint has NOTE=51; 120 breakpoint has NOTE=18
        $w.NOTE | Should -Be 18
    }

    It 'Falls back to 80 map below 80 cols' {
        $w = & (Get-Module LISSTech.UserSessions) { Get-FleetColWidths -TerminalWidth 70 }
        $w.Keys | Should -Not -Contain 'ACCOUNT'
    }
}

Describe 'Format-FleetIdle' {

    It 'Returns dash for idle <= 1m' {
        & (Get-Module LISSTech.UserSessions) { Format-FleetIdle -Span (New-TimeSpan -Seconds 30) } | Should -Be '-'
    }

    It 'Uses {N}m format for <1h' {
        & (Get-Module LISSTech.UserSessions) { Format-FleetIdle -Span (New-TimeSpan -Minutes 47) } | Should -Be '47m'
    }

    It 'Uses H:MM format for 1h..1d' {
        & (Get-Module LISSTech.UserSessions) { Format-FleetIdle -Span (New-TimeSpan -Hours 2 -Minutes 5) } | Should -Be '2:05'
    }

    It 'Uses D d H h format for 1d..7d' {
        & (Get-Module LISSTech.UserSessions) { Format-FleetIdle -Span (New-TimeSpan -Days 3 -Hours 5) } | Should -Be '3d5h'
    }

    It 'Uses {D}d compact form for stale (>=7d)' {
        & (Get-Module LISSTech.UserSessions) { Format-FleetIdle -Span (New-TimeSpan -Days 18) } | Should -Be '18d'
    }
}

Describe 'Format-FleetNote' {

    It 'Disabled session -> disabled' {
        $row = [pscustomobject]@{ RowKind = 'session'; Bucket = '!!'; Session = (New-FleetSession -IsUserDisabled $true); HostNote = $null }
        & (Get-Module LISSTech.UserSessions) { param($r) Format-FleetNote $r } $row | Should -Be 'disabled'
    }

    It 'Stale session -> stale' {
        $row = [pscustomobject]@{ RowKind = 'session'; Bucket = '!'; Session = (New-FleetSession); HostNote = $null }
        & (Get-Module LISSTech.UserSessions) { param($r) Format-FleetNote $r } $row | Should -Be 'stale'
    }

    It 'Current session -> YOU' {
        $row = [pscustomobject]@{ RowKind = 'session'; Bucket = '*'; Session = (New-FleetSession); HostNote = $null }
        & (Get-Module LISSTech.UserSessions) { param($r) Format-FleetNote $r } $row | Should -Be 'YOU'
    }

    It 'Offline host -> offline' {
        $row = [pscustomobject]@{ RowKind = 'offline'; Bucket = 'OFF'; Session = $null; HostNote = $null }
        & (Get-Module LISSTech.UserSessions) { param($r) Format-FleetNote $r } $row | Should -Be 'offline'
    }

    It 'Errored host -> the HostNote text' {
        $row = [pscustomobject]@{ RowKind = 'error'; Bucket = 'ERR'; Session = $null; HostNote = 'RPC unavailable' }
        & (Get-Module LISSTech.UserSessions) { param($r) Format-FleetNote $r } $row | Should -Be 'RPC unavailable'
    }

    It 'Blank bucket -> empty string' {
        $row = [pscustomobject]@{ RowKind = 'session'; Bucket = ''; Session = (New-FleetSession); HostNote = $null }
        & (Get-Module LISSTech.UserSessions) { param($r) Format-FleetNote $r } $row | Should -Be ''
    }
}

AfterAll {
    Remove-Module LISSTech.UserSessions -Force -ErrorAction SilentlyContinue
}
