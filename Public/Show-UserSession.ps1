function Show-UserSession {
    <#
    .SYNOPSIS
        Renders a Textual-style report of user sessions with optional
        asynchronous logoff and ticket-ready report generation.

    .DESCRIPTION
        Scans target servers and renders the results as bordered panels
        with color-coded column data, closed by a status-bar footer.
        With -LogOff, visible sessions are logged off in parallel with
        live docker-pull style progress — each gets a Cylon scanner bar
        while in flight, then flips to a final ✓/✗ on completion.

        With -Report, also generates a ticket-ready artifact (markdown
        or HTML) that captures the scan snapshot, the logoff result (if
        any), and the scope of what was scanned. By default, markdown
        reports go to the clipboard; HTML reports open in your default
        browser via a temp file. Use -ReportPath to save explicitly.

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

    .PARAMETER LogOff
        After rendering, forward visible sessions to the async logoff
        renderer. Respects -WhatIf / -Confirm.

    .PARAMETER Report
        Generate a ticket-ready report in the specified format:
          markdown : clipboard-friendly plain-text tables (HaloPSA-ready)
          html     : rendered HTML on the clipboard (pastes as formatted
                     content into HaloPSA / Outlook / Word) plus a browser
                     preview
        Can be combined with -LogOff — the report then includes the
        pre-logoff session state and the logoff tally.

    .PARAMETER ReportPath
        Explicit file path for the report. When set, the file is written
        silently: HTML does not auto-open the browser, and the clipboard
        is not touched unless -Clipboard is also given.

    .PARAMETER Clipboard
        Force clipboard behavior explicitly. Defaults:
          -Report markdown → clipboard on unless -ReportPath is set
          -Report html     → clipboard on (as CF_HTML / rendered) unless
                             -ReportPath is set
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
        # drop a ticket-ready markdown summary on the clipboard.
        Show-UserSession -LogOff -Confirm:$false -Report markdown

    .EXAMPLE
        # Opens a neobrutal HTML report in your default browser.
        Show-UserSession -Report html

    .EXAMPLE
        # Save explicitly (no auto-open, no clipboard).
        Show-UserSession -Report html -ReportPath C:\Tickets\HALO-1234.html
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
        [switch]$LogOff,

        [ValidateSet('markdown', 'html')]
        [string]$Report,

        [string]$ReportPath,

        [switch]$Clipboard
    )

    begin {
        Write-Debug 'Show-UserSession → begin'
        Write-Debug "  OnlyDisconnected=$OnlyDisconnected MinIdleDays=$MinIdleDays LogOff=$LogOff Report=$Report"

        # If -ReportPath or -Clipboard is given without -Report, infer the
        # format: extension-based for path, markdown default for clipboard.
        if (-not $Report) {
            if ($ReportPath) {
                $Report = switch -Regex ($ReportPath) {
                    '\.html?$' { 'html' }
                    default    { 'markdown' }
                }
                Write-Debug "  -Report inferred as '$Report' from path extension"
            } elseif ($Clipboard) {
                $Report = 'markdown'
                Write-Debug "  -Report defaulted to 'markdown' for -Clipboard"
            }
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

        # -- Render server panels --------------------------------------------
        $serverGroups = @($sessions | Group-Object Server | Sort-Object Name)

        switch ($true) {
            ($serverGroups.Count -eq 0 -and -not $IncludeEmpty) {
                Write-EmptyState
                break
            }
            default {
                foreach ($group in $serverGroups) {
                    Write-Blank
                    Write-ServerPanel -Name $group.Name -Sessions $group.Group
                }
            }
        }

        # -- Compute summary stats -------------------------------------------
        $stateActive = [LISSTech.Wts.WtsConnectState]::Active
        $stateDisc   = [LISSTech.Wts.WtsConnectState]::Disconnected

        $activeCount   = @($sessions.Where({ $_.State -eq $stateActive })).Count
        $discCount     = @($sessions.Where({ $_.State -eq $stateDisc })).Count
        $otherCount    = $sessions.Count - $activeCount - $discCount
        $disabledCount = @($sessions.Where({ $_.IsUserDisabled })).Count
        $uniqueCount   = @($sessions | Select-Object -ExpandProperty Username | Sort-Object -Unique).Count

        $statusBarParams = @{
            Scanned      = $scan.Scanned
            WithSessions = $serverGroups.Count
            Total        = $sessions.Count
            Active       = $activeCount
            Disc         = $discCount
            Other        = $otherCount
            Unique       = $uniqueCount
            Disabled     = $disabledCount
            Offline      = $scan.Offline.Count
            Errored      = $scan.Errored
            Elapsed      = $scan.Elapsed
        }
        Write-StatusBar @statusBarParams

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

            # Build the presentation-layer context once. Both renderers
            # consume the same shape — the view model is the seam.
            $contextArgs = @{
                ScanResult       = $scan
                FilteredSessions = $sessions
                LogoffResult     = $logoffResult
                ScopeInfo        = $scopeInfo
            }
            $reportContext = New-ReportContext @contextArgs

            $content = switch ($Report) {
                'markdown' { Format-ReportMarkdown -Context $reportContext }
                'html'     { Format-ReportHtml     -Context $reportContext }
            }

            $dispatchArgs = @{
                Format  = $Report
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
