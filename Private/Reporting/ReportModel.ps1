# -----------------------------------------------------------------------------
# ReportModel.ps1 — presentation-layer view models.
#
# The renderers never touch $ScanResult directly. They consume a
# ReportContext — a presentation-shaped object built here from the raw
# domain objects.
#
# Why: the scan result's shape is incidental — it grew from what the scanner
# emits. Reports need stable, named concepts the renderers can count on:
# "the disabled-users section," "per-server groupings," "errored-host
# clusters by message." Extract those once, render many times.
#
# This is the seam that lets tests construct synthetic contexts without
# fabricating a complete scan pipeline.
# -----------------------------------------------------------------------------

function New-ReportContext {
    <#
    .SYNOPSIS
        Builds a ReportContext from raw scan + logoff + scope inputs.
        The ReportContext is the ONLY thing renderers consume.

    .OUTPUTS
        [pscustomobject] with the shape:
        {
            Meta              : { Version, Operator, Timestamp, Duration, ... }
            Scope             : { Description, Flags, ... }
            Summary           : { Scanned, Total, Active, Disc, Other, Unique, ... }
            LogoffResult      : <input or $null>
            ServerGroups      : [{ Name, Sessions, Active, Disc }, ...]
            DisabledSessions  : [...]
            OfflineHosts      : [...]
            ErroredGroups     : [{ Message, Hosts }, ...]
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ScanResult,
        [object[]]$FilteredSessions = @(),
        $LogoffResult,
        [hashtable]$ScopeInfo = @{}
    )

    $meta    = New-ReportMeta -ScanResult $ScanResult
    $scope   = New-ReportScope -ScopeInfo $ScopeInfo
    $summary = New-ReportSummary -ScanResult $ScanResult -Sessions $FilteredSessions

    # Per-server groupings — sorted for stable output
    $serverGroups = @(
        $FilteredSessions |
            Group-Object Server |
            Sort-Object Name |
            ForEach-Object {
                $groupSummary = New-ReportSummary -Sessions $_.Group
                [pscustomobject]@{
                    Name     = $_.Name
                    Sessions = @(Get-SortedSessionsForDisplay -Sessions $_.Group)
                    Active   = $groupSummary.Active
                    Disc     = $groupSummary.Disc
                    Other    = $groupSummary.Other
                    Total    = $groupSummary.Total
                }
            }
    )

    # Security-relevant: sessions held by disabled AD accounts
    $disabledSessions = @(
        $FilteredSessions |
            Where-Object IsUserDisabled |
            Sort-Object Server, Username
    )

    # Offline hosts (just names, sorted)
    $offlineHosts = @($ScanResult.Offline | ForEach-Object Name | Sort-Object)

    # Errored hosts grouped by error message — techs care about the
    # pattern ("17 hosts with RPC endpoint unavailable") more than the list
    $erroredGroups = @(
        $ScanResult.Errored |
            Group-Object Error |
            Sort-Object Count -Descending |
            ForEach-Object {
                [pscustomobject]@{
                    Message = $_.Name
                    Hosts   = @($_.Group | ForEach-Object Server | Sort-Object)
                    Count   = $_.Count
                }
            }
    )

    [pscustomobject]@{
        Meta             = $meta
        Scope            = $scope
        Summary          = $summary
        LogoffResult     = $LogoffResult
        ServerGroups     = $serverGroups
        DisabledSessions = $disabledSessions
        OfflineHosts     = $offlineHosts
        ErroredGroups    = $erroredGroups
    }
}

function New-ReportMeta {
    param($ScanResult)

    $ver = (Get-Module LISSTech.UserSessions).Version
    [pscustomobject]@{
        Version   = if ($ver) { "v$ver" } else { 'v?' }
        Operator  = '{0}@{1}' -f [Environment]::UserName, [Environment]::MachineName
        PSEdition = if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { 'Desktop' }
        PSVersion = $PSVersionTable.PSVersion.ToString()
        Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
        Duration  = if ($ScanResult.Elapsed) { '{0:N1}s' -f $ScanResult.Elapsed.TotalSeconds } else { 'n/a' }
    }
}

function New-ReportScope {
    param([hashtable]$ScopeInfo)

    $parts = @()
    if ($ScopeInfo.ComputerName)       { $parts += "computers: $($ScopeInfo.ComputerName -join ', ')" }
    if ($ScopeInfo.Username)           { $parts += "users: $($ScopeInfo.Username -join ', ')" }
    if ($ScopeInfo.UserSearchBase)     { $parts += "OU filter: $($ScopeInfo.UserSearchBase.Count) entries" }
    if ($ScopeInfo.ComputerLdapFilter) { $parts += "LDAP: $($ScopeInfo.ComputerLdapFilter)" }
    if ($ScopeInfo.OnlyDisconnected)   { $parts += 'OnlyDisconnected' }
    if ($ScopeInfo.OnlyDisabled)       { $parts += 'OnlyDisabled' }
    if ($ScopeInfo.MinIdleDays -gt 0)  { $parts += "MinIdleDays=$($ScopeInfo.MinIdleDays)" }

    $description = if ($parts.Count -eq 0) {
        'default scope (all enabled computers, all users)'
    } else {
        $parts -join ' · '
    }

    [pscustomobject]@{
        Description = $description
        IsDefault   = ($parts.Count -eq 0)
        Parts       = $parts
    }
}

function New-ReportSummary {
    <#
    .SYNOPSIS
        Computes session counts for a report section. Used both for the
        top-level summary and per-server subtotals.
    #>
    param(
        $ScanResult,
        [object[]]$Sessions = @()
    )

    $active   = @($Sessions | Where-Object State -eq ([LISSTech.Wts.WtsConnectState]::Active)).Count
    $disc     = @($Sessions | Where-Object State -eq ([LISSTech.Wts.WtsConnectState]::Disconnected)).Count
    $disabled = @($Sessions | Where-Object IsUserDisabled).Count
    $unique   = @($Sessions | ForEach-Object Username | Sort-Object -Unique).Count

    [pscustomobject]@{
        Scanned      = if ($ScanResult) { $ScanResult.Scanned } else { 0 }
        WithSessions = @($Sessions | Group-Object Server).Count
        Total        = $Sessions.Count
        Active       = $active
        Disc         = $disc
        Other        = $Sessions.Count - $active - $disc
        Disabled     = $disabled
        UniqueUsers  = $unique
        Offline      = if ($ScanResult) { @($ScanResult.Offline).Count } else { 0 }
        Errored      = if ($ScanResult) { @($ScanResult.Errored).Count } else { 0 }
    }
}

function Get-SortedSessionsForDisplay {
    <#
    .SYNOPSIS
        Stable sort: active first, then by idle time descending, then by
        username. Used by both dashboard panels and HTML server cards so
        the two always agree.
    #>
    param([object[]]$Sessions)

    $Sessions | Sort-Object @{
        Expression = { $_.State -ne [LISSTech.Wts.WtsConnectState]::Active }
    }, @{
        Expression = { $_.IdleTime }
        Descending = $true
    }, 'Username'
}

# ============================================================================
# Presentation primitives — short-form formatters used by both md and html
# ============================================================================

function Format-SessionLogonShort {
    param($Session)
    if ($null -eq $Session.LogonTime) { return 'unknown' }
    $Session.LogonTime.ToString('M/d h:mm tt')
}

function Format-SessionIdleShort {
    param([TimeSpan]$Span)
    if ($Span.TotalMinutes -lt 1)  { return '-' }
    if ($Span.TotalDays     -ge 1) { return '{0}+{1:D2}:{2:D2}' -f [math]::Floor($Span.TotalDays), $Span.Hours, $Span.Minutes }
    if ($Span.TotalHours    -ge 1) { return '{0}:{1:D2}' -f $Span.Hours, $Span.Minutes }
    '{0}m' -f [math]::Floor($Span.TotalMinutes)
}

function Format-SessionStateShort {
    param($State)
    switch ([string]$State) {
        'Active'       { 'Active' }
        'Disconnected' { 'Disc'   }
        default        { [string]$State }
    }
}

function Test-SessionIdleIsHot {
    <#
    .SYNOPSIS
        Business rule: sessions idle >= 7 days get the "hot" (red) treatment
        in reports. Extracted so there's one place to tune the threshold.
    #>
    param($Session)
    $Session.IdleTime.TotalDays -ge 7
}
