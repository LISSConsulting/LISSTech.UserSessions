function Show-UserSession {
    <#
    .SYNOPSIS
        Renders a full-width fleet table of user sessions with optional
        asynchronous logoff and ticket-ready report generation.

    .DESCRIPTION
        Scans target servers and renders the results as a single FleetGrid
        table: a one-line FLEET summary strip above a column-aligned body
        of sessions plus synthetic rows for offline and errored hosts.
        Rows are priority-sorted — disabled-user sessions first, then stale
        disconnected (≥7 days), then the caller's own session, then the
        rest. Use -GroupByHost for a per-host grouped layout with a tail
        section for empty, offline, and errored hosts.

        With -LogOff, visible sessions are logged off in parallel with
        live docker-pull style progress — each gets a Cylon scanner bar
        while in flight, then flips to a final ✓/✗ on completion.

        With -Report, also generates a ticket-ready HTML artifact that
        captures the scan snapshot, the logoff result (if any), and the
        scope of what was scanned. By default it lands on the clipboard
        as CF_HTML (pastes rendered into HaloPSA / Outlook / Word) and
        opens in your default browser via a temp file. Use -ReportPath
        to save explicitly.

        Not intended for pipeline input. For scripting use
        Find-UserSession; for programmatic logoff use Stop-UserSession.

    .PARAMETER UserSearchBase
        AD OUs whose users to include in the filter. Default is empty
        (no filter — every session on every reachable host is shown).
        Common pattern: set a persistent default in your $PROFILE via
        $PSDefaultParameterValues['Show-UserSession:UserSearchBase'].

    .PARAMETER OnlyDisconnected
        Restrict display and logoff to Disconnected sessions.

    .PARAMETER OnlyDisabled
        Restrict display and logoff to sessions belonging to disabled AD
        accounts. Useful for offboarding sweeps and security incident
        response.

    .PARAMETER MinIdleDays
        Restrict display and logoff to sessions idle at least N days.

    .PARAMETER GroupByHost
        Render sessions clustered under per-host band headers instead of
        a single flat priority-sorted table. Hosts are ordered by highest
        severity present (disabled > stale > current > normal). Offline,
        errored, and zero-session hosts move to a tail section below
        the table.

    .PARAMETER LogOff
        After rendering, forward visible sessions to the async logoff
        renderer. Respects -WhatIf / -Confirm.

    .PARAMETER Report
        Generate a ticket-ready HTML report. Default behavior: render to
        a temp file, open it in the browser, and place CF_HTML on the
        clipboard for rich-text paste into HaloPSA / Outlook / Word.
        Implied when -ReportPath is given.

        Can be combined with -LogOff — the report then includes the
        pre-logoff session state and the logoff tally.

    .PARAMETER ReportPath
        Explicit file path for the report. When set, the file is written
        silently: the browser is not auto-opened, and the clipboard is
        not touched unless -Clipboard is also given.

    .PARAMETER Clipboard
        Force clipboard behavior explicitly. Default with -Report (no
        -ReportPath): clipboard is set to CF_HTML for rendered paste.
        Pass -Clipboard:$false to suppress the clipboard when it would
        otherwise fire.

    .EXAMPLE
        Show-UserSession

    .EXAMPLE
        Show-UserSession -OnlyDisconnected -MinIdleDays 7 -LogOff

    .EXAMPLE
        Show-UserSession -OnlyDisabled -LogOff     # offboarding sweep

    .EXAMPLE
        # Maintenance window canonical command: execute the logoff AND
        # drop a rendered HTML report on the clipboard for the ticket.
        Show-UserSession -LogOff -Confirm:$false -Report

    .EXAMPLE
        # Opens a neobrutal HTML report in your default browser.
        Show-UserSession -Report

    .EXAMPLE
        # Save explicitly (no auto-open, no clipboard).
        Show-UserSession -Report -ReportPath C:\Tickets\HALO-1234.html
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [string[]]$UserSearchBase,
        [string[]]$Username,

        [Alias('Server', 'Name')]
        [string[]]$ComputerName,

        [Alias('ServerLdapFilter')]
        [string]$ComputerLdapFilter = '',

        [ValidateRange(1, 128)]
        [int]$ThrottleLimit = 16,

        [ValidateRange(100, 30000)]
        [int]$PingTimeoutMs = 2000,

        [switch]$OnlyDisconnected,
        [switch]$OnlyDisabled,

        [ValidateRange(0, 3650)]
        [int]$MinIdleDays = 0,

        [switch]$IncludeEmpty,
        [switch]$GroupByHost,
        [switch]$LogOff,

        [switch]$Report,

        [string]$ReportPath,

        [switch]$Clipboard
    )

    begin {
        Write-Debug 'Show-UserSession → begin'
        Write-Debug "  OnlyDisconnected=$OnlyDisconnected MinIdleDays=$MinIdleDays LogOff=$LogOff Report=$Report"

        # -ReportPath or -Clipboard implies -Report; the user wouldn't pass
        # them otherwise.
        if (-not $Report -and ($ReportPath -or $Clipboard)) {
            $Report = $true
            Write-Debug '  -Report inferred from -ReportPath / -Clipboard'
        }
    }

    end {
        Write-Banner

        # -- Scan ------------------------------------------------------------
        $scanParams = @{
            UserSearchBase     = $UserSearchBase
            Username           = $Username
            ComputerName       = $ComputerName
            ComputerLdapFilter = $ComputerLdapFilter
            ThrottleLimit      = $ThrottleLimit
            PingTimeoutMs      = $PingTimeoutMs
        }
        $scan = Invoke-UserSessionScan @scanParams

        Write-Step 'Users enumerated'     "$($scan.Users) filter entries"
        Write-Step 'Connectivity checked' "$($scan.Scanned) online · $($scan.Offline.Count) offline"
        Write-Step 'Scan complete'        ('{0} servers in {1:N1}s' -f $scan.Scanned, $scan.Elapsed.TotalSeconds)

        # -- Apply filters ---------------------------------------------------
        $sessions = @($scan.Sessions)

        if ($OnlyDisconnected) {
            $sessions = @(
                $sessions | Where-Object {
                    $_.State -eq [LISSTech.Wts.WtsConnectState]::Disconnected
                }
            )
            Write-Debug "Show-UserSession → after OnlyDisconnected: $($sessions.Count) session(s)"
        }

        if ($OnlyDisabled) {
            $sessions = @($sessions | Where-Object IsUserDisabled)
            Write-Debug "Show-UserSession → after OnlyDisabled: $($sessions.Count) session(s)"
        }

        if ($MinIdleDays -gt 0) {
            $sessions = @(
                $sessions | Where-Object {
                    $_.IdleTime.TotalDays -ge $MinIdleDays
                }
            )
            Write-Debug "Show-UserSession → after MinIdleDays=${MinIdleDays}: $($sessions.Count) session(s)"
        }

        # -- Compute summary stats -------------------------------------------
        $stateActive = [LISSTech.Wts.WtsConnectState]::Active
        $stateDisc   = [LISSTech.Wts.WtsConnectState]::Disconnected
        $staleLimit  = [TimeSpan]::FromDays(7)

        $activeCount   = @($sessions.Where({ $_.State -eq $stateActive })).Count
        $discCount     = @($sessions.Where({ $_.State -eq $stateDisc })).Count
        $disabledCount = @($sessions.Where({ $_.IsUserDisabled })).Count
        $staleCount    = @($sessions.Where({
            $_.State -eq $stateDisc -and $_.IdleTime -ge $staleLimit
        })).Count
        $currentCount  = @($sessions.Where({ $_.IsCurrent })).Count
        $serverGroups  = @($sessions | Select-Object -ExpandProperty Server | Sort-Object -Unique)

        # -- Summary strip (one line, above the table) -----------------------
        Write-Blank
        $stripParams = @{
            Scanned      = $scan.Scanned
            WithSessions = $serverGroups.Count
            Total        = $sessions.Count
            Active       = $activeCount
            Disc         = $discCount
            Disabled     = $disabledCount
            Stale        = $staleCount
            Current      = $currentCount
            Offline      = $scan.Offline.Count
            Errored      = @($scan.Errored).Count
            Elapsed      = $scan.Elapsed
        }
        Write-FleetSummaryStrip @stripParams
        Write-Blank

        # -- Render FleetGrid ------------------------------------------------
        if ($sessions.Count -eq 0 -and $scan.Offline.Count -eq 0 -and @($scan.Errored).Count -eq 0 -and -not $IncludeEmpty) {
            Write-EmptyState
        } else {
            $gridParams = @{
                Sessions         = $sessions
                Offline          = @($scan.Offline)
                Errored          = @($scan.Errored)
                GroupByHost      = [bool]$GroupByHost
                AllScannedHosts  = if ($GroupByHost -and $scan.Scanned -gt 0) {
                    # Best-effort: sessions + offline + errored host names (we
                    # don't have the full scanned-host list here). Callers who
                    # want empty-host footnotes should supply -ComputerName.
                    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($s in $sessions)      { [void]$names.Add($s.Server) }
                    foreach ($o in @($scan.Offline)) {
                        $n = if ($o.PSObject.Properties['Name']) { $o.Name } else { [string]$o }
                        [void]$names.Add($n)
                    }
                    foreach ($e in @($scan.Errored)) { [void]$names.Add($e.Server) }
                    if ($ComputerName) { foreach ($c in $ComputerName) { [void]$names.Add($c) } }
                    $names
                } else { @() }
            }
            Write-FleetGrid @gridParams
        }
        Write-Blank

        # -- Optional async logoff -------------------------------------------
        $logoffResult = $null

        if ($LogOff -and $sessions.Count -gt 0) {
            $targets = @($sessions.Where({ -not $_.IsCurrent }))

            if ($targets.Count -eq 0) {
                Write-Debug 'Show-UserSession → LogOff: nothing to log off (all sessions are current)'
            } else {
                $serverCount = @($targets | Select-Object -ExpandProperty Server | Sort-Object -Unique).Count
                $description = '{0} user session(s) across {1} server(s)' -f $targets.Count, $serverCount

                # Single batch confirmation — per-item prompts would block the
                # async renderer. For per-item confirmation, use Stop-UserSession
                # directly via the pipeline.
                if ($PSCmdlet.ShouldProcess($description, 'WTSLogoffSession (async)')) {
                    $logoffParams = @{
                        Sessions      = $targets
                        ThrottleLimit = $ThrottleLimit
                    }
                    $logoffResult = Start-AsyncLogoff @logoffParams
                }
            }
        }

        # -- Optional report generation --------------------------------------
        if ($Report) {
            $scopeInfo = @{
                ComputerName       = $ComputerName
                Username           = $Username
                UserSearchBase     = $UserSearchBase
                ComputerLdapFilter = $ComputerLdapFilter
                OnlyDisconnected   = [bool]$OnlyDisconnected
                OnlyDisabled       = [bool]$OnlyDisabled
                MinIdleDays        = $MinIdleDays
            }

            $contextArgs = @{
                ScanResult       = $scan
                FilteredSessions = $sessions
                LogoffResult     = $logoffResult
                ScopeInfo        = $scopeInfo
            }
            $reportContext = New-ReportContext @contextArgs
            $content = Format-ReportHtml -Context $reportContext

            $dispatchArgs = @{
                Content = $content
            }
            if ($PSBoundParameters.ContainsKey('ReportPath')) { $dispatchArgs.ReportPath = $ReportPath }
            if ($PSBoundParameters.ContainsKey('Clipboard'))  { $dispatchArgs.Clipboard  = $Clipboard }

            $dispatchResult = Invoke-ReportDispatch @dispatchArgs
            Write-Debug "Report dispatch → $($dispatchResult | ConvertTo-Json -Compress)"
        }

        Write-Debug 'Show-UserSession → end'
    }
}
