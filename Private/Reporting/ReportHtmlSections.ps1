# -----------------------------------------------------------------------------
# ReportHtmlSections.ps1 — pure section renderers for the HTML report.
#
# Each New-*Section function:
#   - Takes its own slice of the ReportContext as input
#   - Returns an HTML string (never modifies shared state)
#   - Has no knowledge of other sections
#
# Composition lives in ReportHtml.ps1. Adding a new section means writing
# a new function and adding one line to the composer. Existing sections
# don't change — that's OCP in its useful form.
# -----------------------------------------------------------------------------

function New-HtmlBannerSection {
    param($Meta)

    $version = ConvertTo-HtmlSafe $Meta.Version
    @"
<section class="banner">
  <div>
    <h1>LISSTech.UserSessions<span class="version">$version</span></h1>
    <p class="tagline">Enumerate, audit, and log off Terminal Services sessions across AD.</p>
  </div>
  <div class="brand">
    <div class="brand-mark">LISS</div>
    <div class="brand-sub">Technologies</div>
  </div>
</section>
"@
}

function New-HtmlMetaStripSection {
    param($Meta, $Scope)

    $operator  = ConvertTo-HtmlSafe $Meta.Operator
    $timestamp = ConvertTo-HtmlSafe $Meta.Timestamp
    $duration  = ConvertTo-HtmlSafe $Meta.Duration
    $scope     = ConvertTo-HtmlSafe $Scope.Description

    @"
<section class="meta-strip">
  <div class="meta-item"><span class="meta-label">Operator</span><span class="meta-value">$operator</span></div>
  <div class="meta-item"><span class="meta-label">Scan Time</span><span class="meta-value">$timestamp</span></div>
  <div class="meta-item"><span class="meta-label">Duration</span><span class="meta-value">$duration</span></div>
  <div class="meta-item"><span class="meta-label">Scope</span><span class="meta-value">$scope</span></div>
</section>
"@
}

function New-HtmlLogoffSection {
    <#
    .SYNOPSIS
        Renders the logoff result banner. Returns empty string if no
        logoff was performed — lets the composer blindly concatenate.
    #>
    param($LogoffResult)

    if ($null -eq $LogoffResult) { return '' }

    $severity = if ($LogoffResult.Failed -eq 0) { 'success' }
                elseif ($LogoffResult.Succeeded -gt 0) { 'mixed' }
                else { 'failure' }
    $icon = if ($LogoffResult.Failed -eq 0) { '✓' } else { '!' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine(@"
<section class="logoff $severity">
  <div class="logoff-icon">$icon</div>
  <div>
    <div class="logoff-count mono">$($LogoffResult.Succeeded) LOGGED OFF</div>
    <div class="logoff-sub mono">$($LogoffResult.Failed) failed · $($LogoffResult.Skipped) skipped</div>
  </div>
</section>
"@)

    if ($LogoffResult.Failed -gt 0) {
        [void]$sb.AppendLine('<section class="alert danger">')
        [void]$sb.AppendLine('  <h3>⚠ Logoff failures</h3>')
        [void]$sb.AppendLine('  <table class="sessions"><thead><tr><th>Server</th><th>User</th><th>Session ID</th><th>Error</th></tr></thead><tbody>')
        foreach ($f in $LogoffResult.Failures) {
            $server = ConvertTo-HtmlSafe $f.Server
            $user   = ConvertTo-HtmlSafe $f.Username
            $err    = ConvertTo-HtmlSafe $f.Error
            [void]$sb.AppendLine("  <tr><td class=`"mono`">$server</td><td class=`"mono`">$user</td><td class=`"mono`">id$($f.SessionId)</td><td>$err</td></tr>")
        }
        [void]$sb.AppendLine('  </tbody></table>')
        [void]$sb.AppendLine('</section>')
    }

    $sb.ToString()
}

function New-HtmlSummarySection {
    param($Summary)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<h2 class="section-title">Summary <span class="badge">at a glance</span></h2>')
    [void]$sb.AppendLine('<section class="summary-grid">')
    [void]$sb.AppendLine("  <div class=`"stat-card`"><div class=`"stat-label`">Scanned</div><div class=`"stat-value mono`">$($Summary.Scanned)</div></div>")
    [void]$sb.AppendLine("  <div class=`"stat-card`"><div class=`"stat-label`">Sessions</div><div class=`"stat-value mono`">$($Summary.Total)</div></div>")
    [void]$sb.AppendLine("  <div class=`"stat-card active`"><div class=`"stat-label`">● Active</div><div class=`"stat-value mono`">$($Summary.Active)</div></div>")
    [void]$sb.AppendLine("  <div class=`"stat-card disc`"><div class=`"stat-label`">○ Disconnected</div><div class=`"stat-value mono`">$($Summary.Disc)</div></div>")
    [void]$sb.AppendLine("  <div class=`"stat-card`"><div class=`"stat-label`">◆ Users</div><div class=`"stat-value mono`">$($Summary.UniqueUsers)</div></div>")
    if ($Summary.Disabled -gt 0) {
        [void]$sb.AppendLine("  <div class=`"stat-card disabled`"><div class=`"stat-label`">⚠ Disabled</div><div class=`"stat-value mono`">$($Summary.Disabled)</div></div>")
    }
    if ($Summary.Offline -gt 0) {
        [void]$sb.AppendLine("  <div class=`"stat-card offline`"><div class=`"stat-label`">Offline</div><div class=`"stat-value mono`">$($Summary.Offline)</div></div>")
    }
    if ($Summary.Errored -gt 0) {
        [void]$sb.AppendLine("  <div class=`"stat-card errored`"><div class=`"stat-label`">✗ Errored</div><div class=`"stat-value mono`">$($Summary.Errored)</div></div>")
    }
    [void]$sb.AppendLine('</section>')
    $sb.ToString()
}

function New-HtmlDisabledUsersSection {
    param([object[]]$DisabledSessions)

    if ($DisabledSessions.Count -eq 0) { return '' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<h2 class="section-title">⚠ Disabled users <span class="badge">security</span></h2>')
    [void]$sb.AppendLine('<section class="alert danger">')
    [void]$sb.AppendLine('  <h3>Sessions for disabled AD accounts</h3>')
    [void]$sb.AppendLine('  <p>Disabling an AD account does not end its existing sessions. Review — this is either an offboarding gap or an incident.</p>')
    [void]$sb.AppendLine('</section>')
    [void]$sb.AppendLine('<div class="server-card"><table class="sessions">')
    [void]$sb.AppendLine('  <thead><tr><th>Server</th><th>User</th><th>State</th><th>Session</th><th>ID</th><th>Idle</th><th>Logon</th></tr></thead><tbody>')

    foreach ($s in $DisabledSessions) {
        [void]$sb.AppendLine((Get-HtmlDisabledSessionRow -Session $s))
    }

    [void]$sb.AppendLine('  </tbody></table></div>')
    $sb.ToString()
}

function Get-HtmlDisabledSessionRow {
    param($Session)

    $server     = ConvertTo-HtmlSafe $Session.Server
    $user       = ConvertTo-HtmlSafe $Session.Username
    $winStation = if ([string]::IsNullOrWhiteSpace($Session.WinStation)) { '-' } else { ConvertTo-HtmlSafe $Session.WinStation }
    $stateClass = Get-HtmlStateClass -State $Session.State
    $stateText  = ConvertTo-HtmlSafe (Format-SessionStateShort $Session.State)
    $idle       = ConvertTo-HtmlSafe (Format-SessionIdleShort $Session.IdleTime)
    $logon      = ConvertTo-HtmlSafe (Format-SessionLogonShort $Session)

    "    <tr><td class=`"mono`">$server</td><td class=`"user-cell disabled`">$user<span class=`"disabled-badge`">⚠ DISABLED</span></td><td><span class=`"state-pill $stateClass`">$stateText</span></td><td class=`"mono`">$winStation</td><td class=`"mono`">id$($Session.SessionId)</td><td class=`"mono`">$idle</td><td class=`"mono`">$logon</td></tr>"
}

function New-HtmlServerGroupsSection {
    param([object[]]$ServerGroups)

    if ($ServerGroups.Count -eq 0) { return '' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<h2 class="section-title">Sessions by server</h2>')
    foreach ($group in $ServerGroups) {
        [void]$sb.AppendLine((New-HtmlServerCard -Group $group))
    }
    $sb.ToString()
}

function New-HtmlServerCard {
    param($Group)

    $serverName = ConvertTo-HtmlSafe $Group.Name

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<article class="server-card">')
    [void]$sb.AppendLine('  <header class="server-header">')
    [void]$sb.AppendLine("    <div class=`"server-name`">$serverName</div>")
    [void]$sb.AppendLine('    <div class="server-chips">')
    if ($Group.Active -gt 0) { [void]$sb.AppendLine("      <span class=`"chip active`">● $($Group.Active)</span>") }
    if ($Group.Disc   -gt 0) { [void]$sb.AppendLine("      <span class=`"chip disc`">○ $($Group.Disc)</span>") }
    [void]$sb.AppendLine('    </div>')
    [void]$sb.AppendLine('  </header>')
    [void]$sb.AppendLine('  <table class="sessions">')
    [void]$sb.AppendLine('    <thead><tr><th></th><th>User</th><th>State</th><th>Session</th><th>ID</th><th>Idle</th><th>Logon</th></tr></thead><tbody>')

    foreach ($session in $Group.Sessions) {
        [void]$sb.AppendLine((Get-HtmlSessionRow -Session $session))
    }

    [void]$sb.AppendLine('    </tbody></table>')
    [void]$sb.AppendLine('</article>')
    $sb.ToString()
}

function Get-HtmlSessionRow {
    param($Session)

    $user       = ConvertTo-HtmlSafe $Session.Username
    $winStation = if ([string]::IsNullOrWhiteSpace($Session.WinStation)) { '-' } else { ConvertTo-HtmlSafe $Session.WinStation }

    $isActive   = $Session.State -eq [LISSTech.Wts.WtsConnectState]::Active
    $isDisabled = [bool]$Session.IsUserDisabled
    $isIdleHot  = Test-SessionIdleIsHot -Session $Session

    $markGlyph = if ($Session.IsCurrent) { '★' } elseif ($isActive) { '●' } else { '○' }
    $markClass = if ($Session.IsCurrent) { 'current' } elseif ($isActive) { 'active' } else { 'disc' }

    $stateClass    = Get-HtmlStateClass -State $Session.State
    $stateText     = ConvertTo-HtmlSafe (Format-SessionStateShort $Session.State)
    $userCellClass = if ($isDisabled) { 'user-cell disabled' } else { 'user-cell' }
    $disabledBadge = if ($isDisabled) { '<span class="disabled-badge">⚠ DISABLED</span>' } else { '' }
    $idleClass     = if ($isIdleHot) { 'mono idle hot' } else { 'mono idle' }

    $idle  = ConvertTo-HtmlSafe (Format-SessionIdleShort $Session.IdleTime)
    $logon = ConvertTo-HtmlSafe (Format-SessionLogonShort $Session)

    "    <tr><td><span class=`"mark $markClass`">$markGlyph</span></td><td class=`"$userCellClass`">$user$disabledBadge</td><td><span class=`"state-pill $stateClass`">$stateText</span></td><td class=`"mono`">$winStation</td><td class=`"mono`">id$($Session.SessionId)</td><td class=`"$idleClass`">$idle</td><td class=`"mono`">$logon</td></tr>"
}

function Get-HtmlStateClass {
    param($State)
    if     ($State -eq [LISSTech.Wts.WtsConnectState]::Active)       { 'active' }
    elseif ($State -eq [LISSTech.Wts.WtsConnectState]::Disconnected) { 'disc' }
    else                                                             { 'other' }
}

function New-HtmlOfflineHostsSection {
    param([object[]]$OfflineHosts)

    if ($OfflineHosts.Count -eq 0) { return '' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<h2 class="section-title">Offline hosts</h2>')
    [void]$sb.AppendLine('<div class="pill-list">')
    foreach ($name in $OfflineHosts) {
        $safeName = ConvertTo-HtmlSafe $name
        [void]$sb.AppendLine("  <span class=`"pill`">$safeName</span>")
    }
    [void]$sb.AppendLine('</div>')
    $sb.ToString()
}

function New-HtmlErroredHostsSection {
    param([object[]]$ErroredGroups)

    if ($ErroredGroups.Count -eq 0) { return '' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<h2 class="section-title">Errored hosts</h2>')
    foreach ($group in $ErroredGroups) {
        $message = ConvertTo-HtmlSafe $group.Message
        [void]$sb.AppendLine('<article class="error-group">')
        [void]$sb.AppendLine('  <header class="error-group-header">')
        [void]$sb.AppendLine("    <span class=`"msg`">✗ $message</span>")
        [void]$sb.AppendLine("    <span class=`"count mono`">$($group.Count) hosts</span>")
        [void]$sb.AppendLine('  </header>')
        [void]$sb.AppendLine('  <div class="error-group-body"><div class="pill-list">')
        foreach ($hostName in $group.Hosts) {
            $safeName = ConvertTo-HtmlSafe $hostName
            [void]$sb.AppendLine("    <span class=`"pill`">$safeName</span>")
        }
        [void]$sb.AppendLine('  </div></div>')
        [void]$sb.AppendLine('</article>')
    }
    $sb.ToString()
}

function New-HtmlFooterSection {
    param($Meta)

    $version   = ConvertTo-HtmlSafe $Meta.Version
    $timestamp = ConvertTo-HtmlSafe $Meta.Timestamp
    $operator  = ConvertTo-HtmlSafe $Meta.Operator

    @"
<footer class="footer">
  <div>Generated by <strong>LISSTech.UserSessions $version</strong> · $timestamp · $operator</div>
</footer>
"@
}
