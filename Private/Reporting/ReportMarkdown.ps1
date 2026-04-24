# -----------------------------------------------------------------------------
# ReportMarkdown.ps1 — markdown report composition.
#
# Symmetric with ReportHtml.ps1: same input (ReportContext), different
# output (HaloPSA/GitHub-friendly tables of markdown). Extracted into
# its own file so the composer here can evolve independently from HTML.
# -----------------------------------------------------------------------------

function Format-ReportMarkdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context
    )

    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine((Get-MarkdownHeader -Meta $Context.Meta -Scope $Context.Scope))
    $logoffSection = Get-MarkdownLogoffSection -LogoffResult $Context.LogoffResult
    if ($logoffSection) { [void]$sb.AppendLine($logoffSection) }

    [void]$sb.AppendLine((Get-MarkdownSummarySection -Summary $Context.Summary))

    $disabledSection = Get-MarkdownDisabledSection -DisabledSessions $Context.DisabledSessions
    if ($disabledSection) { [void]$sb.AppendLine($disabledSection) }

    $serverSection = Get-MarkdownServerGroupsSection -ServerGroups $Context.ServerGroups
    if ($serverSection) { [void]$sb.AppendLine($serverSection) }

    $offlineSection = Get-MarkdownOfflineSection -OfflineHosts $Context.OfflineHosts
    if ($offlineSection) { [void]$sb.AppendLine($offlineSection) }

    $erroredSection = Get-MarkdownErroredSection -ErroredGroups $Context.ErroredGroups
    if ($erroredSection) { [void]$sb.AppendLine($erroredSection) }

    [void]$sb.AppendLine((Get-MarkdownFooter -Meta $Context.Meta))

    $sb.ToString()
}

# ============================================================================
# Section helpers
# ============================================================================

function Get-MarkdownHeader {
    param($Meta, $Scope)

    @"
# Session Report — $($Meta.Timestamp)

**Module:** LISSTech.UserSessions $($Meta.Version)
**Operator:** $($Meta.Operator)
**PowerShell:** $($Meta.PSEdition) $($Meta.PSVersion)
**Scope:** $($Scope.Description)
**Duration:** $($Meta.Duration)

"@
}

function Get-MarkdownLogoffSection {
    param($LogoffResult)
    if ($null -eq $LogoffResult) { return '' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('## Logoff result')
    [void]$sb.AppendLine()
    $emoji = if ($LogoffResult.Failed -gt 0) { '⚠' } else { '✓' }
    [void]$sb.AppendLine("**$emoji $($LogoffResult.Succeeded) logged off · $($LogoffResult.Failed) failed · $($LogoffResult.Skipped) skipped**")
    [void]$sb.AppendLine()

    if ($LogoffResult.Failed -gt 0) {
        [void]$sb.AppendLine('### Failures')
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('| Server | User | Session | Error |')
        [void]$sb.AppendLine('|---|---|---|---|')
        foreach ($f in $LogoffResult.Failures) {
            [void]$sb.AppendLine(('| {0} | {1} | id{2} | {3} |' -f $f.Server, $f.Username, $f.SessionId, $f.Error))
        }
        [void]$sb.AppendLine()
    }
    $sb.ToString()
}

function Get-MarkdownSummarySection {
    param($Summary)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('## Summary')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| Metric | Count |')
    [void]$sb.AppendLine('|---|---|')
    [void]$sb.AppendLine(('| Servers scanned | {0} |' -f $Summary.Scanned))
    [void]$sb.AppendLine(('| Servers with sessions | {0} |' -f $Summary.WithSessions))
    [void]$sb.AppendLine(('| Total sessions | {0} |' -f $Summary.Total))
    [void]$sb.AppendLine(('| Active | {0} |' -f $Summary.Active))
    [void]$sb.AppendLine(('| Disconnected | {0} |' -f $Summary.Disc))
    [void]$sb.AppendLine(('| Unique users | {0} |' -f $Summary.UniqueUsers))
    if ($Summary.Disabled -gt 0) { [void]$sb.AppendLine(('| ⚠ Disabled users with sessions | {0} |' -f $Summary.Disabled)) }
    if ($Summary.Offline  -gt 0) { [void]$sb.AppendLine(('| Offline hosts | {0} |'                 -f $Summary.Offline))  }
    if ($Summary.Errored  -gt 0) { [void]$sb.AppendLine(('| Errored hosts | {0} |'                 -f $Summary.Errored))  }
    [void]$sb.AppendLine()
    $sb.ToString()
}

function Get-MarkdownDisabledSection {
    param([object[]]$DisabledSessions)
    if ($DisabledSessions.Count -eq 0) { return '' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('## ⚠ Sessions for disabled users')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('Disabling an AD account does not end its existing sessions. These require attention — offboarding gap or incident response:')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| Server | User | State | Session | ID | Idle | Logon |')
    [void]$sb.AppendLine('|---|---|---|---|---|---|---|')

    foreach ($s in $DisabledSessions) {
        $fmtArgs = @(
            $s.Server,
            $s.Username,
            (Format-SessionStateShort $s.State),
            $s.WinStation,
            $s.SessionId,
            (Format-SessionIdleShort $s.IdleTime),
            (Format-SessionLogonShort $s)
        )
        [void]$sb.AppendLine(('| {0} | **{1}** | {2} | {3} | id{4} | {5} | {6} |' -f $fmtArgs))
    }
    [void]$sb.AppendLine()
    $sb.ToString()
}

function Get-MarkdownServerGroupsSection {
    param([object[]]$ServerGroups)
    if ($ServerGroups.Count -eq 0) { return '' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('## Sessions by server')
    [void]$sb.AppendLine()

    foreach ($group in $ServerGroups) {
        $parts = @()
        if ($group.Active -gt 0) { $parts += "● $($group.Active) active" }
        if ($group.Disc   -gt 0) { $parts += "○ $($group.Disc) disc"    }
        [void]$sb.AppendLine("### $($group.Name) — $($parts -join ' · ')")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('| User | State | Session | ID | Idle | Logon |')
        [void]$sb.AppendLine('|---|---|---|---|---|---|')

        foreach ($s in $group.Sessions) {
            $uname      = if ($s.IsUserDisabled) { "⚠ **$($s.Username)**" } else { $s.Username }
            $winStation = if ([string]::IsNullOrWhiteSpace($s.WinStation)) { '-' } else { $s.WinStation }
            $fmtArgs = @(
                $uname,
                (Format-SessionStateShort $s.State),
                $winStation,
                $s.SessionId,
                (Format-SessionIdleShort $s.IdleTime),
                (Format-SessionLogonShort $s)
            )
            [void]$sb.AppendLine(('| {0} | {1} | {2} | id{3} | {4} | {5} |' -f $fmtArgs))
        }
        [void]$sb.AppendLine()
    }
    $sb.ToString()
}

function Get-MarkdownOfflineSection {
    param([object[]]$OfflineHosts)
    if ($OfflineHosts.Count -eq 0) { return '' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('## Offline hosts')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine(($OfflineHosts -join ', '))
    [void]$sb.AppendLine()
    $sb.ToString()
}

function Get-MarkdownErroredSection {
    param([object[]]$ErroredGroups)
    if ($ErroredGroups.Count -eq 0) { return '' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('## Errored hosts')
    [void]$sb.AppendLine()
    foreach ($g in $ErroredGroups) {
        [void]$sb.AppendLine("**✗ $($g.Message)** — $($g.Count) host(s)")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine(($g.Hosts -join ', '))
        [void]$sb.AppendLine()
    }
    $sb.ToString()
}

function Get-MarkdownFooter {
    param($Meta)
    @"
---

*Generated by LISSTech.UserSessions $($Meta.Version) at $($Meta.Timestamp) by $($Meta.Operator).*
"@
}
