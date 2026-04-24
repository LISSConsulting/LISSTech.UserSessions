# -----------------------------------------------------------------------------
# Display primitives for LISSTech.UserSessions
#
# Design constraints:
#   * Windows Server 2016 conhost with VT processing enabled
#   * Consolas font coverage (no braille, no rounded corners)
#   * 256-color ANSI for richer styling than Write-Host -ForegroundColor
#
# The async logoff view uses ANSI cursor positioning to repaint rows in
# place, docker-pull style: each session gets a Cylon progress bar while
# in flight, then flips to a final ✓/✗ state on completion.
# -----------------------------------------------------------------------------

# ============================================================================
# Console encoding + VT enable
# ============================================================================
#
# Two independent things have to be right for this module's output:
#
#   1. Console OutputEncoding must be UTF-8. Server 2016 conhost defaults to
#      the OEM codepage (437 or 1252), which maps our 3-byte UTF-8 glyphs
#      (●, ○, ★, ◆, ⚠, box-drawing chars) to single '?' bytes on write.
#      Setting [Console]::OutputEncoding forces the runtime to encode
#      strings as UTF-8 before handing them to WriteFile.
#
#   2. VT processing (ENABLE_VIRTUAL_TERMINAL_PROCESSING, flag 0x0004) must
#      be on so the console interprets ESC[...m and cursor-movement escapes
#      as formatting instead of printing them literally.
#
# Both are set unconditionally at module import; cheap, idempotent.

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    Write-Debug 'Format-Display → OutputEncoding set to UTF-8'
} catch {
    Write-Debug "Format-Display → OutputEncoding set failed: $($_.Exception.Message)"
}

if (-not ('LISSTech.UserSessions.VT' -as [type])) {
    Write-Debug 'Format-Display → registering VT interop type'

    Add-Type -Namespace 'LISSTech.UserSessions' -Name 'VT' -MemberDefinition @'
        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
        public static extern System.IntPtr GetStdHandle(int nStdHandle);
        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool GetConsoleMode(System.IntPtr hConsoleHandle, out uint lpMode);
        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool SetConsoleMode(System.IntPtr hConsoleHandle, uint dwMode);
'@
}

try {
    $stdOut = [LISSTech.UserSessions.VT]::GetStdHandle(-11)
    $mode   = 0
    if ([LISSTech.UserSessions.VT]::GetConsoleMode($stdOut, [ref]$mode)) {
        [void][LISSTech.UserSessions.VT]::SetConsoleMode($stdOut, $mode -bor 0x0004)
        Write-Debug 'Format-Display → VT processing enabled'
    }
} catch {
    Write-Debug "Format-Display → VT enable failed: $($_.Exception.Message)"
}

# ============================================================================
# Module-scope constants
# ============================================================================

$script:ESC         = [char]27
$script:CSI         = "$script:ESC["
$script:PanelWidth  = 96          # outer width of all panels
$script:BarWidth    = 20          # Cylon scanner length
$script:TimeWidth   = 5           # fixed width for all elapsed strings

# Column widths for the session table. Defined once so the header row and
# the data rows can't drift out of alignment — a bug class that has bitten
# us before. The "lead" is the prefix before USER (the mark + separator).
# Header prepends '  ' (2 spaces) where rows use 1 space + mark + 1 space
# = 3 chars, so header's USER width must be 1 greater than row's to align
# STATE and everything after it.
$script:Col = @{
    RowLead     = 3    # ' ' + mark + ' '
    HeadLead    = 2    # '  '
    Username    = 20
    UserGap     = 2    # spaces between username cell and STATE
    State       = 7
    WinStation  = 14
    SessionId   = 9
    Idle        = 15
    LogonFull   = 19   # "M/d/yyyy h:mm tt" worst case
    LogonShort  = 13   # truncated when ⚠ DISABLED badge appends
}

# FleetGrid column widths keyed by terminal-width breakpoint. Each entry is a
# hashtable mapping column name → width; absent columns are omitted from the
# render at that breakpoint. Cells are separated by a single space, and the
# sum of widths + (N - 1) separators must equal the breakpoint width.
#
# Degradation principle: drop lowest-triage-value columns first.
#   80  drops LOGON, ACCOUNT; folds SESSION into NOTE
#   100 adds SESSION and LOGON back; ACCOUNT still folded into NOTE
#   120 is canonical
#   160 widens USER/SERVER/NOTE
#   200 adds DOMAIN and LASTINPUT
$script:FleetCol = @{
    80  = [ordered]@{ PRI = 3; SERVER = 14; USER = 16; ST = 4; IDLE =  7;                                 NOTE = 30 }
    100 = [ordered]@{ PRI = 3; SERVER = 16; USER = 17; ST = 4; SESSION = 12; IDLE =  7; LOGON = 12;       NOTE = 21 }
    120 = [ordered]@{ PRI = 3; SERVER = 18; USER = 18; ST = 4; SESSION = 12; IDLE =  7; LOGON = 14; ACCOUNT = 10; NOTE = 18 }
    160 = [ordered]@{ PRI = 3; SERVER = 22; USER = 22; ST = 4; SESSION = 16; IDLE =  7; LOGON = 17; ACCOUNT = 10; NOTE = 51 }
    200 = [ordered]@{ PRI = 3; SERVER = 24; USER = 24; DOMAIN = 12; ST = 4; SESSION = 18; IDLE =  7; LASTINPUT = 17; LOGON = 17; ACCOUNT = 10; NOTE = 44 }
}

$script:FleetStaleThreshold = [TimeSpan]::FromDays(7)
$script:FleetIdleWarmThreshold = [TimeSpan]::FromHours(1)

function Format-FleetBucketGlyph {
    <# Returns the 2-char glyph for the PRI column. Total column is 3 chars
       because the cell is left-padded by one space for visual rhythm. #>
    param([string]$Bucket)
    switch ($Bucket) {
        'ERR' { 'ERR' }
        'OFF' { 'OFF' }
        '!!'  { '!!' }
        '!'   { '! ' }
        '*'   { '* ' }
        default { '  ' }
    }
}

function Get-FleetBucketColor {
    <# Palette key for the PRI glyph. #>
    param([string]$Bucket)
    $p = $script:Palette
    switch ($Bucket) {
        'ERR'   { $p.Error }
        'OFF'   { $p.TitleDim }
        '!!'    { $p.Error }
        '!'     { $p.Warning }
        '*'     { $p.Current }
        default { $p.TitleDim }
    }
}

function Get-FleetIdleColor {
    <# Idle color by bucket: fresh <1h dim, warm 1h..7d warning, hot >=7d hot. #>
    param([TimeSpan]$Span)
    $p = $script:Palette
    if ($Span -ge $script:FleetStaleThreshold)    { return $p.IdleHot }
    if ($Span -ge $script:FleetIdleWarmThreshold) { return $p.Warning }
    $p.Logon
}

function Format-FleetNote {
    <# NOTE column content per row kind / bucket. #>
    param($Row)
    switch ($Row.RowKind) {
        'error'   { return $Row.HostNote }
        'offline' { return 'offline' }
    }
    switch ($Row.Bucket) {
        '!!' { 'disabled' }
        '!'  { 'stale' }
        '*'  { 'YOU' }
        default { '' }
    }
}

function Get-FleetNoteColor {
    param($Row)
    $p = $script:Palette
    switch ($Row.RowKind) {
        'error'   { return $p.Error }
        'offline' { return $p.TitleDim }
    }
    switch ($Row.Bucket) {
        '!!'    { $p.Error }
        '!'     { $p.Warning }
        '*'     { $p.Current }
        default { $p.TitleDim }
    }
}

function Format-FleetAccount {
    <# ACCOUNT column: 'DISABLED' or 'OK' for sessions, '—' for host rows. #>
    param($Row)
    if ($Row.RowKind -ne 'session') { return '—' }
    if ($Row.Session.IsUserDisabled) { 'DISABLED' } else { 'OK' }
}

function Get-FleetAccountColor {
    param($Row)
    $p = $script:Palette
    if ($Row.RowKind -ne 'session') { return $p.TitleDim }
    if ($Row.Session.IsUserDisabled) { $p.Error } else { $p.TitleDim }
}

# Column renderer — one entry per known column. Each takes ($Row, $Widths,
# $Palette) and returns (visible text, palette color). Format-FleetCell
# applies Format-Fixed + the color ESC codes.
$script:FleetCellRenderers = @{
    PRI = {
        param($Row, $W, $P)
        @((Format-FleetBucketGlyph $Row.Bucket).PadRight($W.PRI), (Get-FleetBucketColor $Row.Bucket))
    }
    SERVER = {
        param($Row, $W, $P)
        @((Format-Fixed -Text $Row.Server -Width $W.SERVER), $P.Server)
    }
    USER = {
        param($Row, $W, $P)
        if ($Row.RowKind -ne 'session') { return @((Format-Fixed -Text '—' -Width $W.USER), $P.TitleDim) }
        $color = if ($Row.Session.IsUserDisabled) { $P.Error } else { $P.Username }
        @((Format-Fixed -Text $Row.Session.Username -Width $W.USER), $color)
    }
    DOMAIN = {
        param($Row, $W, $P)
        $text = if ($Row.RowKind -ne 'session') { '—' } else { $Row.Session.Domain }
        @((Format-Fixed -Text $text -Width $W.DOMAIN), $P.TitleDim)
    }
    ST = {
        param($Row, $W, $P)
        if ($Row.RowKind -ne 'session') { return @((Format-Fixed -Text '—' -Width $W.ST), $P.TitleDim) }
        $text = Format-State $Row.Session.State
        $color = if ($Row.Session.State -eq [LISSTech.Wts.WtsConnectState]::Active) { $P.Active } else { $P.Disc }
        @((Format-Fixed -Text $text -Width $W.ST), $color)
    }
    SESSION = {
        param($Row, $W, $P)
        if ($Row.RowKind -ne 'session') { return @((Format-Fixed -Text '—' -Width $W.SESSION), $P.TitleDim) }
        $text = if ([string]::IsNullOrWhiteSpace($Row.Session.WinStation)) { '—' } else { $Row.Session.WinStation }
        @((Format-Fixed -Text $text -Width $W.SESSION), $P.WinStation)
    }
    IDLE = {
        param($Row, $W, $P)
        if ($Row.RowKind -ne 'session') { return @((Format-Fixed -Text '—' -Width $W.IDLE), $P.TitleDim) }
        $text = Format-FleetIdle -Span $Row.Session.IdleTime
        @((Format-Fixed -Text $text -Width $W.IDLE), (Get-FleetIdleColor $Row.Session.IdleTime))
    }
    LASTINPUT = {
        param($Row, $W, $P)
        if ($Row.RowKind -ne 'session' -or $null -eq $Row.Session.LastInputTime) {
            return @((Format-Fixed -Text '—' -Width $W.LASTINPUT), $P.TitleDim)
        }
        @((Format-Fixed -Text ($Row.Session.LastInputTime.ToString('M/d/yyyy h:mm tt')) -Width $W.LASTINPUT), $P.Logon)
    }
    LOGON = {
        param($Row, $W, $P)
        if ($Row.RowKind -ne 'session' -or $null -eq $Row.Session.LogonTime) {
            return @((Format-Fixed -Text '—' -Width $W.LOGON), $P.TitleDim)
        }
        $fmt = if ($W.LOGON -ge 16) { 'M/d/yyyy h:mm tt' } else { 'M/d h:mm tt' }
        @((Format-Fixed -Text ($Row.Session.LogonTime.ToString($fmt)) -Width $W.LOGON), $P.Logon)
    }
    ACCOUNT = {
        param($Row, $W, $P)
        @((Format-Fixed -Text (Format-FleetAccount $Row) -Width $W.ACCOUNT), (Get-FleetAccountColor $Row))
    }
    NOTE = {
        param($Row, $W, $P)
        @((Format-Fixed -Text (Format-FleetNote $Row) -Width $W.NOTE), (Get-FleetNoteColor $Row))
    }
}

function Format-FleetRow {
    <#
    .SYNOPSIS
        Renders one fleet row as a colored ANSI line, honoring the active
        width map. Columns absent from $Widths are skipped.
    #>
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)]$Widths
    )

    $p = $script:Palette
    $cells = foreach ($col in $Widths.Keys) {
        $renderer = $script:FleetCellRenderers[$col]
        if (-not $renderer) { continue }
        $pair = & $renderer $Row $Widths $p
        $text  = $pair[0]
        $color = $pair[1]
        $color + $text + $p.Reset
    }
    ' ' + ($cells -join ' ')
}

function Format-FleetHeaderRow {
    param([Parameter(Mandatory)]$Widths)
    $p = $script:Palette
    $cells = foreach ($col in $Widths.Keys) {
        $w = $Widths[$col]
        $color = if ($col -eq 'SERVER') { $p.Warning } else { $p.Header }
        $color + (Format-Fixed -Text $col -Width $w) + $p.Reset
    }
    ' ' + ($cells -join ' ')
}

function Format-FleetDividerRow {
    param([Parameter(Mandatory)]$Widths)
    $p = $script:Palette
    $cells = foreach ($col in $Widths.Keys) {
        $w = $Widths[$col]
        $p.TitleDim + ('─' * $w) + $p.Reset
    }
    ' ' + ($cells -join ' ')
}

function Write-FleetSummaryStrip {
    <#
    .SYNOPSIS
        One-line FLEET summary strip above the table. Conditional chips
        only render when their count > 0 (or host > 0 for offline/error).
    #>
    param(
        [int]$Scanned,
        [int]$WithSessions,
        [int]$Total,
        [int]$Active,
        [int]$Disc,
        [int]$Disabled,
        [int]$Stale,
        [int]$Current,
        [int]$Offline,
        [int]$Errored,
        [TimeSpan]$Elapsed
    )

    $p = $script:Palette
    $empty = $Scanned - $WithSessions
    if ($empty -lt 0) { $empty = 0 }

    $pipe = $p.TitleDim + ' | ' + $p.Reset
    $parts = @()

    # Always-present
    $parts += $p.Bold + $p.TitleFg + 'FLEET' + $p.Reset
    $parts += $p.Username + ('{0} hosts' -f $Scanned)    + $p.Reset
    $parts += $p.Username + ('{0} active hosts' -f $WithSessions) + $p.Reset
    $parts += $p.Username + ('{0} sessions' -f $Total)   + $p.Reset
    $parts += $p.Active   + ('{0} active' -f $Active)    + $p.Reset
    $parts += $p.Disc     + ('{0} disc' -f $Disc)        + $p.Reset

    # Conditional
    if ($Disabled -gt 0) { $parts += $p.Error   + ('{0} disabled' -f $Disabled) + $p.Reset }
    if ($Stale    -gt 0) { $parts += $p.Warning + ('{0} stale'    -f $Stale)    + $p.Reset }
    if ($Current  -gt 0) { $parts += $p.Current + ('{0} you'      -f $Current)  + $p.Reset }
    if ($empty    -gt 0) { $parts += $p.TitleDim + ('{0} empty'   -f $empty)    + $p.Reset }
    if ($Offline  -gt 0) { $parts += $p.TitleDim + ('{0} offline' -f $Offline)  + $p.Reset }
    if ($Errored  -gt 0) { $parts += $p.Error   + ('{0} error'    -f $Errored)  + $p.Reset }

    $parts += $p.TitleDim + ('{0:N1}s' -f $Elapsed.TotalSeconds) + $p.Reset

    Write-AnsiLine (' ' + ($parts -join $pipe))
}

function Get-FleetGroupedWidths {
    <# Drops the SERVER column (host name provided by band header) and
       gives the reclaimed width to NOTE so the table still spans the
       full breakpoint width. #>
    param([Parameter(Mandatory)]$Widths)

    if (-not $Widths.Contains('SERVER')) { return $Widths }
    $reclaim = $Widths['SERVER']
    $result = [ordered]@{}
    foreach ($key in $Widths.Keys) {
        if ($key -eq 'SERVER') { continue }
        $result[$key] = $Widths[$key]
    }
    if ($result.Contains('NOTE')) {
        # NOTE absorbs the SERVER width + the separator that would have sat
        # between SERVER and its neighbor (1 extra space in the join).
        $result['NOTE'] = $result['NOTE'] + $reclaim + 1
    }
    $result
}

function Write-FleetHostBand {
    <# One-line host header for grouped mode. Example:
         RDS-01  5 sessions  3 active  2 disc  [!! 1]  [! 1]
       Leading single space matches the row indent. #>
    param(
        [string]$Server,
        [object[]]$Rows
    )

    $p = $script:Palette
    $active = @($Rows | Where-Object { $_.RowKind -eq 'session' -and $_.Session.State -eq [LISSTech.Wts.WtsConnectState]::Active }).Count
    $disc   = @($Rows | Where-Object { $_.RowKind -eq 'session' -and $_.Session.State -ne [LISSTech.Wts.WtsConnectState]::Active }).Count
    $total  = $active + $disc
    $disabled = @($Rows | Where-Object { $_.Bucket -eq '!!' }).Count
    $stale    = @($Rows | Where-Object { $_.Bucket -eq '!'  }).Count
    $you      = @($Rows | Where-Object { $_.Bucket -eq '*'  }).Count

    $sessLabel = if ($total -eq 1) { '1 session' } else { "$total sessions" }

    $pipe = $p.TitleDim + '  ·  ' + $p.Reset
    $parts = @()
    $parts += $p.Bold + $p.Server + $Server + $p.Reset
    $parts += $p.Username + $sessLabel + $p.Reset
    $parts += $p.Active  + ('{0} active' -f $active) + $p.Reset
    $parts += $p.Disc    + ('{0} disc'   -f $disc)   + $p.Reset
    if ($disabled -gt 0) { $parts += $p.Error   + ('!! {0} disabled' -f $disabled) + $p.Reset }
    if ($stale    -gt 0) { $parts += $p.Warning + ('! {0} stale'     -f $stale)    + $p.Reset }
    if ($you      -gt 0) { $parts += $p.Current + 'YOU'                            + $p.Reset }

    Write-AnsiLine ('')
    Write-AnsiLine (' ' + ($parts -join $pipe))
}

function Write-FleetHostTail {
    <# Tail section for grouped mode showing OFFLINE / ERRORED hosts grouped
       by error message, and the count of zero-session hosts that were
       suppressed from the body. #>
    param(
        [object[]]$Offline = @(),
        [object[]]$Errored = @(),
        [int]$EmptyCount   = 0,
        [string[]]$EmptyHosts = @()
    )

    $p = $script:Palette
    $hadAny = $false

    if ($EmptyCount -gt 0) {
        Write-AnsiLine ('')
        $list = if ($EmptyHosts.Count -le 8) {
            ($EmptyHosts -join ', ')
        } else {
            (($EmptyHosts | Select-Object -First 8) -join ', ') + (', +{0} more' -f ($EmptyHosts.Count - 8))
        }
        Write-AnsiLine (' ' + $p.TitleDim + ('Empty hosts ({0}): ' -f $EmptyCount) + $list + $p.Reset)
        $hadAny = $true
    }

    if ($Offline.Count -gt 0) {
        Write-AnsiLine ('')
        $names = foreach ($o in $Offline) {
            if ($null -ne $o -and $o.PSObject.Properties['Name']) { $o.Name } else { [string]$o }
        }
        $hostWord = if ($Offline.Count -eq 1) { 'host' } else { 'hosts' }
        Write-AnsiLine (' ' + $p.TitleDim + 'OFFLINE  ' + $p.Reset + $p.Username + ('{0} {1}: ' -f $Offline.Count, $hostWord) + $p.Reset + ($names -join ', '))
        $hadAny = $true
    }

    if ($Errored.Count -gt 0) {
        Write-AnsiLine ('')
        $grouped = $Errored | Group-Object Error | Sort-Object Count -Descending
        foreach ($g in $grouped) {
            $hosts = ($g.Group | Select-Object -ExpandProperty Server | Sort-Object) -join ', '
            Write-AnsiLine (' ' + $p.Error + 'ERROR    ' + $p.Reset + $p.TitleFg + $g.Name + $p.Reset + $p.TitleDim + ('  [{0}] ' -f $g.Count) + $hosts + $p.Reset)
        }
        $hadAny = $true
    }

    $hadAny
}

function Write-FleetGrid {
    <#
    .SYNOPSIS
        Renders the fleet dashboard: a single full-width table of all
        sessions plus synthetic rows for offline/errored hosts.
    .PARAMETER Sessions
        Filtered session objects.
    .PARAMETER Offline
        Objects with a Name property (or strings) for offline hosts.
    .PARAMETER Errored
        Objects with Server and Error properties for hosts that failed
        the WTS scan.
    .PARAMETER TerminalWidth
        Override terminal width for testing; defaults to current window.
    #>
    param(
        [object[]]$Sessions = @(),
        [object[]]$Offline  = @(),
        [object[]]$Errored  = @(),
        [int]$TerminalWidth = [Math]::Max(80, [Console]::WindowWidth),
        [switch]$GroupByHost,
        [string[]]$AllScannedHosts = @()
    )

    $widths = Get-FleetColWidths -TerminalWidth $TerminalWidth
    $rows = Get-FleetOrderedRows -Sessions $Sessions -Offline $Offline -Errored $Errored

    if (-not $GroupByHost) {
        Write-AnsiLine (Format-FleetHeaderRow -Widths $widths)
        Write-AnsiLine (Format-FleetDividerRow -Widths $widths)

        if ($rows.Count -eq 0) {
            $p = $script:Palette
            Write-AnsiLine ('  ' + $p.TitleDim + '(no matching sessions)' + $p.Reset)
            return
        }

        foreach ($row in $rows) {
            Write-AnsiLine (Format-FleetRow -Row $row -Widths $widths)
        }
        return
    }

    # -GroupByHost: separate tail for OFF/ERR, host bands for sessions.
    $groupedWidths = Get-FleetGroupedWidths -Widths $widths
    $sessionRows = @($rows | Where-Object { $_.RowKind -eq 'session' })

    # Compute empty hosts: in scope but had no sessions and no explicit
    # offline/error listing. AllScannedHosts is optional — when supplied
    # we can show an empty-hosts footnote.
    $sessionHosts = @($sessionRows | Select-Object -ExpandProperty Server -Unique)
    $offlineNames = foreach ($o in $Offline) {
        if ($o.PSObject.Properties['Name']) { $o.Name } else { [string]$o }
    }
    $errorNames = @($Errored | Select-Object -ExpandProperty Server)
    $knownHosts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($h in $sessionHosts) { [void]$knownHosts.Add($h) }
    foreach ($h in $offlineNames) { [void]$knownHosts.Add($h) }
    foreach ($h in $errorNames)   { [void]$knownHosts.Add($h) }
    $emptyHosts = @($AllScannedHosts | Where-Object { -not $knownHosts.Contains($_) })

    if ($sessionRows.Count -eq 0) {
        $p = $script:Palette
        Write-AnsiLine ('  ' + $p.TitleDim + '(no matching sessions)' + $p.Reset)
    } else {
        # Host order: by highest-severity bucket in the host, then host asc.
        $hostPriority = @{}
        foreach ($row in $sessionRows) {
            $cur = $hostPriority[$row.Server]
            if ($null -eq $cur -or $row.Rank -lt $cur) {
                $hostPriority[$row.Server] = $row.Rank
            }
        }

        $hostOrder = $hostPriority.Keys | Sort-Object @{ Expression = { $hostPriority[$_] } }, @{ Expression = { $_ } }

        # Header rendered once above the first band — repeating it per band
        # is k9s-style noise when most hosts have 1–3 rows.
        Write-AnsiLine (Format-FleetHeaderRow -Widths $groupedWidths)
        Write-AnsiLine (Format-FleetDividerRow -Widths $groupedWidths)

        foreach ($server in $hostOrder) {
            $hostRows = @($sessionRows | Where-Object { $_.Server -eq $server })
            Write-FleetHostBand -Server $server -Rows $hostRows
            foreach ($row in $hostRows) {
                Write-AnsiLine (Format-FleetRow -Row $row -Widths $groupedWidths)
            }
        }
    }

    [void](Write-FleetHostTail -Offline $Offline -Errored $Errored -EmptyCount $emptyHosts.Count -EmptyHosts $emptyHosts)
}

function Get-FleetRowPriority {
    <#
    .SYNOPSIS
        Maps a fleet row (session or synthetic host row) to a priority bucket.
    .DESCRIPTION
        Returns a hashtable:
            Bucket = 'ERR' | 'OFF' | '!!' | '!' | '*' | ''
            Rank   = integer sort key (lower = higher priority)
        Buckets ordered high-to-low: ERR > OFF > !! disabled > ! stale >
        * current > blank. Host-level (ERR/OFF) ranks above session-level
        so fleet-wide host outages surface at the top of the table.
    #>
    param(
        [string]$RowKind,                          # 'session' | 'error' | 'offline'
        [object]$Session                           # session object when RowKind = 'session'
    )

    switch ($RowKind) {
        'error'   { return @{ Bucket = 'ERR'; Rank = 0 } }
        'offline' { return @{ Bucket = 'OFF'; Rank = 1 } }
    }

    if ($Session.IsUserDisabled) {
        return @{ Bucket = '!!'; Rank = 2 }
    }

    $isDisc = $Session.State -eq [LISSTech.Wts.WtsConnectState]::Disconnected
    if ($isDisc -and $Session.IdleTime -ge $script:FleetStaleThreshold) {
        return @{ Bucket = '!'; Rank = 3 }
    }

    if ($Session.IsCurrent) {
        return @{ Bucket = '*'; Rank = 4 }
    }

    @{ Bucket = ''; Rank = 5 }
}

function Get-FleetOrderedRows {
    <#
    .SYNOPSIS
        Assembles the fleet row list from a scan result and returns it
        sorted for FleetGrid rendering.
    .DESCRIPTION
        Produces PSCustomObjects with shape:
            Bucket    priority bucket glyph
            Rank      integer sort key
            RowKind   'session' | 'error' | 'offline'
            Server    host name
            Session   the session object, or $null for host rows
            HostNote  text for the NOTE column on host rows

        Sorted by (Rank asc, within-bucket tiebreakers per the design brief):
          !! disabled:  State=Active before Disc, IdleTime desc, Server, User
          !  stale:     IdleTime desc, Server, User
          *  current:   State=Active before other, IdleTime desc, Server, User
          blank:        State=Active before other, IdleTime desc, Server, User
          ERR / OFF:    Server asc
    #>
    param(
        [object[]]$Sessions = @(),
        [object[]]$Offline  = @(),
        [object[]]$Errored  = @()
    )

    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($s in $Sessions) {
        $p = Get-FleetRowPriority -RowKind 'session' -Session $s
        $rows.Add([pscustomobject]@{
            Bucket   = $p.Bucket
            Rank     = $p.Rank
            RowKind  = 'session'
            Server   = $s.Server
            Session  = $s
            HostNote = $null
        })
    }

    foreach ($srv in $Offline) {
        $name = if ($null -ne $srv -and $srv.PSObject.Properties['Name']) { $srv.Name } else { [string]$srv }
        $p = Get-FleetRowPriority -RowKind 'offline'
        $rows.Add([pscustomobject]@{
            Bucket   = $p.Bucket
            Rank     = $p.Rank
            RowKind  = 'offline'
            Server   = $name
            Session  = $null
            HostNote = 'offline'
        })
    }

    foreach ($e in $Errored) {
        $name = if ($null -ne $e.Server) { $e.Server } elseif ($e.PSObject.Properties['Name']) { $e.Name } else { [string]$e }
        $p = Get-FleetRowPriority -RowKind 'error'
        $rows.Add([pscustomobject]@{
            Bucket   = $p.Bucket
            Rank     = $p.Rank
            RowKind  = 'error'
            Server   = $name
            Session  = $null
            HostNote = $e.Error
        })
    }

    # Active-state preference within session buckets (Active sorts ahead of
    # Disconnected/other via ascending numeric key). Host rows short-circuit
    # to 0 so their Rank alone places them — the other keys are tiebreakers.
    # IdleTime for session rows; host rows contribute TimeSpan.Zero.
    $sortProps = @(
        @{ Expression = 'Rank' }
        @{ Expression = {
            if ($_.RowKind -ne 'session') { 0 }
            elseif ($_.Session.State -eq [LISSTech.Wts.WtsConnectState]::Active) { 0 }
            else { 1 }
        } }
        @{ Expression = {
            if ($_.RowKind -ne 'session') { [TimeSpan]::Zero }
            else { $_.Session.IdleTime }
        }; Descending = $true }
        @{ Expression = 'Server' }
        @{ Expression = { if ($_.Session) { $_.Session.Username } else { '' } } }
    )
    $rows | Sort-Object -Property $sortProps
}

function Get-FleetColWidths {
    <#
    .SYNOPSIS
        Returns the appropriate FleetGrid column-width map for the current
        terminal width, picking the largest breakpoint whose total fits.
    #>
    param(
        [int]$TerminalWidth = [Math]::Max(80, [Console]::WindowWidth)
    )

    $breakpoints = $script:FleetCol.Keys | Sort-Object -Descending
    foreach ($bp in $breakpoints) {
        if ($TerminalWidth -ge $bp) { return $script:FleetCol[$bp] }
    }
    return $script:FleetCol[80]
}

# Box-drawing glyphs (all in Consolas — no rounded variants)
$script:Box = @{
    H     = '─'; V    = '│'
    TL    = '┌'; TR   = '┐'; BL  = '└'; BR  = '┘'
    TJL   = '├'; TJR  = '┤'; TJT = '┬'; TJB = '┴'
    Cross = '┼'
}

# 256-color palette, tuned for dark terminals with Consolas
$script:Palette = @{
    BorderDim    = "${script:CSI}38;5;238m"
    BorderBright = "${script:CSI}38;5;67m"
    TitleFg      = "${script:CSI}38;5;117m"
    Server       = "${script:CSI}38;5;111m"      # host names in FleetGrid — periwinkle, kin to TitleFg
    TitleDim     = "${script:CSI}38;5;244m"
    Header       = "${script:CSI}38;5;231m"      # bright white for column headers
    Username     = "${script:CSI}38;5;252m"
    Active       = "${script:CSI}38;5;114m"
    ActiveBright = "${script:CSI}38;5;156m"
    Disc         = "${script:CSI}38;5;179m"
    DiscBright   = "${script:CSI}38;5;215m"
    Current      = "${script:CSI}38;5;213m"
    WinStation   = "${script:CSI}38;5;109m"
    SessionId    = "${script:CSI}38;5;145m"
    IdleDim      = "${script:CSI}38;5;244m"
    IdleHot      = "${script:CSI}38;5;203m"
    Logon        = "${script:CSI}38;5;244m"
    Success      = "${script:CSI}38;5;114m"
    Warning      = "${script:CSI}38;5;179m"
    Error        = "${script:CSI}38;5;203m"
    Info         = "${script:CSI}38;5;109m"
    Scanner      = "${script:CSI}38;5;81m"
    ScannerDim   = "${script:CSI}38;5;24m"
    Reset        = "${script:CSI}0m"
    Bold         = "${script:CSI}1m"
    Dim          = "${script:CSI}2m"
}

# ============================================================================
# String primitives
# ============================================================================

function Get-VisibleLength {
    <# Returns the visible (printable) length of a string, stripping ANSI. #>
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    return ([regex]::Replace($Text, "$script:ESC\[[0-9;]*[A-Za-z]", '')).Length
}

function Format-Fixed {
    <# Pads or truncates (with trailing '.') to exactly $Width chars. #>
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory)][int]$Width,
        [switch]$Right
    )

    if ($null -eq $Text) { $Text = '' }

    if ($Text.Length -gt $Width) {
        if ($Width -le 1) { return '.' }
        return $Text.Substring(0, $Width - 1) + '.'
    }

    if ($Right) { $Text.PadLeft($Width) } else { $Text.PadRight($Width) }
}

function Format-Duration {
    <#
    Formats a TimeSpan as a compact fixed-width string (width = TimeWidth):
        "  5ms"   " 43ms"   "340ms"   " 1.2s"   "12.3s"   "  40s"

    Discipline: all durations render at exactly TimeWidth chars so columns
    align regardless of magnitude. 40s takes less space than 23ms in the
    raw format, but both occupy 5 chars once padded.
    #>
    param([TimeSpan]$Span)

    $ms = $Span.TotalMilliseconds
    $raw = switch ($ms) {
        ({ $_ -lt 1000  }) { '{0:N0}ms' -f $_ ; break }
        ({ $_ -lt 10000 }) { '{0:N1}s'  -f ($_ / 1000) ; break }
        ({ $_ -lt 60000 }) { '{0:N0}s'  -f ($_ / 1000) ; break }
        default            { '{0:N0}m'  -f ($_ / 60000) }
    }
    return $raw.PadLeft($script:TimeWidth)
}

function Format-IdleSpan {
    <# Idle-time column in session rows (width varies; no padding here). #>
    param([TimeSpan]$Span)

    switch ($Span) {
        ({ $_ -le [TimeSpan]::FromMinutes(1) }) { '-'; break }
        ({ $_.TotalDays  -ge 1 })               { '{0}+{1:D2}:{2:D2}' -f [math]::Floor($_.TotalDays), $_.Hours, $_.Minutes; break }
        ({ $_.TotalHours -ge 1 })               { '{0}:{1:D2}' -f $_.Hours, $_.Minutes; break }
        default                                 { '{0}m' -f [math]::Floor($_.TotalMinutes) }
    }
}

function Format-State {
    <# Abbreviates a WtsConnectState for the STATE column (≤4 chars). #>
    param([LISSTech.Wts.WtsConnectState]$State)

    switch ($State) {
        'Active'       { 'Act' }
        'Disconnected' { 'Disc' }
        'Connected'    { 'Conn' }
        'ConnectQuery' { 'CnQ' }
        'Listen'       { 'Lsn' }
        'Reset'        { 'Rst' }
        'Shadow'       { 'Shw' }
        'Idle'         { 'Idle' }
        default        { [string]$State }
    }
}

function Format-FleetIdle {
    <# Compact idle formatter that fits a 7-char column without truncation.
       <1m '-', <1h '{N}m', <1d 'H:MM', <7d '{D}d{H}h', >=7d '{D}d' #>
    param([TimeSpan]$Span)

    if ($Span -le [TimeSpan]::FromMinutes(1)) { return '-' }
    if ($Span.TotalDays -ge 7)  { return ('{0}d' -f [math]::Floor($Span.TotalDays)) }
    if ($Span.TotalDays -ge 1)  { return ('{0}d{1}h' -f [math]::Floor($Span.TotalDays), $Span.Hours) }
    if ($Span.TotalHours -ge 1) { return ('{0}:{1:D2}' -f $Span.Hours, $Span.Minutes) }
    '{0}m' -f [math]::Floor($Span.TotalMinutes)
}

function Format-CylonBar {
    <#
    Knight Rider / Cylon scanner: lead block with trailing glow that bounces
    left-right across the bar. Used for indeterminate progress since
    WTSLogoffSession has no progress API.

        [░▒▓█       ]   [    █▓▒░   ]   [       █▓▒░]
    #>
    param(
        [double]$ElapsedSec,
        [int]$Width = $script:BarWidth
    )

    $cycle = 2 * $Width
    $pos   = [int]([math]::Floor($ElapsedSec * 18) % $cycle)
    $isGoingRight = $pos -lt $Width
    $lead  = if ($isGoingRight) { $pos } else { $cycle - 1 - $pos }

    $chars = [char[]]('░' * $Width)
    $trail = @('▒', '▓', '█')

    for ($i = 0; $i -lt $trail.Count; $i++) {
        $offset = $trail.Count - 1 - $i
        $idx = if ($isGoingRight) { $lead - $offset } else { $lead + $offset }
        if ($idx -ge 0 -and $idx -lt $Width) {
            $chars[$idx] = $trail[$i]
        }
    }

    -join $chars
}

# ============================================================================
# Write helpers
# ============================================================================

function Write-Blank {
    [Console]::Out.WriteLine('')
}

function Write-AnsiLine {
    <# Emits a pre-composed string with terminal reset + newline. #>
    param([string]$Text)
    [Console]::Out.WriteLine($Text + $script:Palette.Reset)
}

# ============================================================================
# Banner + scan progress
# ============================================================================

function Write-Banner {
    <#
        Three-line banner:
          line 1: module name (bold) + version (dim), right-aligned "LISS Technologies"
          line 2: tagline describing what the tool does
          line 3: runtime context — caller@host, PS edition/version, timestamp

        All values computed at call-time so version updates follow the
        manifest automatically.
    #>
    $p = $script:Palette
    $b = $script:Box
    $inner = $script:PanelWidth - 2

    $moduleName = 'LISSTech.UserSessions.Session'
    $version    = (Get-Module LISSTech.UserSessions).Version
    $versionStr = if ($version) { "v$version" } else { 'v?' }
    $brand      = 'LISS Technologies'

    $tagline    = 'Enumerate, audit, and log off Terminal Services sessions across AD.'

    $who   = '{0}@{1}' -f [Environment]::UserName, [Environment]::MachineName
    $psEd  = if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { 'Desktop' }
    $psVer = $PSVersionTable.PSVersion.ToString()
    $now   = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $context = '{0}  ·  PS {1} {2}  ·  {3}' -f $who, $psEd, $psVer, $now

    # --- Line 1: module name + version, right-aligned brand ------------------
    $left1  = '  ' + $p.Bold + $p.TitleFg + $moduleName + $p.Reset + '  ' +
              $p.TitleDim + $versionStr + $p.Reset
    $right1 = $p.Bold + $p.Info + $brand + $p.Reset + '  '
    $leftVis1  = Get-VisibleLength $left1
    $rightVis1 = Get-VisibleLength $right1
    $gap1 = $inner - $leftVis1 - $rightVis1
    if ($gap1 -lt 1) { $gap1 = 1 }
    $line1 = $left1 + (' ' * $gap1) + $right1

    # --- Line 2: tagline -----------------------------------------------------
    $line2raw = '  ' + $p.TitleDim + $tagline + $p.Reset
    $pad2 = $inner - (Get-VisibleLength $line2raw)
    if ($pad2 -lt 0) { $pad2 = 0 }
    $line2 = $line2raw + (' ' * $pad2)

    # --- Line 3: runtime context --------------------------------------------
    $line3raw = '  ' + $p.Logon + $context + $p.Reset
    $pad3 = $inner - (Get-VisibleLength $line3raw)
    if ($pad3 -lt 0) { $pad3 = 0 }
    $line3 = $line3raw + (' ' * $pad3)

    Write-Blank
    Write-AnsiLine ($p.BorderBright + $b.TL + ($b.H * $inner) + $b.TR)
    Write-AnsiLine ($p.BorderBright + $b.V + $line1 + $p.BorderBright + $b.V)
    Write-AnsiLine ($p.BorderBright + $b.V + $line2 + $p.BorderBright + $b.V)
    Write-AnsiLine ($p.BorderBright + $b.V + $line3 + $p.BorderBright + $b.V)
    Write-AnsiLine ($p.BorderBright + $b.BL + ($b.H * $inner) + $b.BR)
    Write-Blank
}

function Write-Step {
    <# One-line progress indicator under the banner. #>
    param([string]$Label, [string]$Detail)

    $p = $script:Palette
    $parts = @(
        '  '
        $p.Success + '>' + $p.Reset
        ' '
        $p.TitleDim + (Format-Fixed -Text $Label -Width 22) + $p.Reset
        ' '
        $p.Logon + $Detail + $p.Reset
    )
    Write-AnsiLine (-join $parts)
}

# ============================================================================
# Server panel
# ============================================================================

function Write-ServerPanel {
    param(
        [string]$Name,
        [object[]]$Sessions
    )

    $p = $script:Palette
    $b = $script:Box
    $inner = $script:PanelWidth - 2

    $count = $Sessions.Count
    $activeCount = @($Sessions.Where({ $_.State -eq [LISSTech.Wts.WtsConnectState]::Active })).Count
    $discCount   = $count - $activeCount

    # --- Top border with embedded title and count chip -----------------------
    $titleText = " $Name "

    $chipParts = @()
    if ($activeCount -gt 0) {
        $chipParts += ($p.Active + '● ' + $p.Reset + $p.Username + $activeCount + $p.Reset)
    }
    if ($discCount -gt 0) {
        $chipParts += ($p.Disc + '○ ' + $p.Reset + $p.Username + $discCount + $p.Reset)
    }
    if ($chipParts.Count -eq 0) {
        $chipParts = @($p.TitleDim + 'empty' + $p.Reset)
    }

    $chip = (
        $p.TitleDim + '[ ' + $p.Reset +
        ($chipParts -join ($p.TitleDim + ' · ' + $p.Reset)) +
        $p.TitleDim + ' ]' + $p.Reset
    )

    # Top border layout:  TL H title (H*n) SP chip SP H TR
    # Visible chars summed: 1 + 1 + len(title) + n + 1 + chipVis + 1 + 1 + 1
    # That must equal the outer PanelWidth. Solving for n:
    #   n = PanelWidth - 6 - len(title) - chipVis
    # Note: inner = PanelWidth - 2 (for the two side borders), so equivalently
    #   n = inner - 4 - len(title) - chipVis
    $titleVisible = $titleText.Length
    $chipVisible  = Get-VisibleLength $chip
    $dashCount    = $inner - 4 - $titleVisible - $chipVisible
    if ($dashCount -lt 3) { $dashCount = 3 }

    $topParts = @(
        $p.BorderBright + $b.TL + $b.H
        $p.Bold + $p.TitleFg + $titleText + $p.Reset
        $p.BorderBright + ($b.H * $dashCount) + ' '
        $chip
        ' ' + $p.BorderBright + $b.H + $b.TR
    )
    Write-AnsiLine (-join $topParts)

    # --- Column header row ---------------------------------------------------
    # Header and row must put STATE (and every column after) at the same
    # absolute x-position. Row lead is 3 chars (' ' + mark + ' '); header
    # lead is 2 chars ('  '). To compensate, header's USER cell is 1 wider
    # than the row's — that way STATE lands at the same column in both.
    $c = $script:Col
    $headerUserWidth = $c.Username + $c.UserGap + ($c.RowLead - $c.HeadLead)
    $headerText = (
        (' ' * $c.HeadLead) +
        (Format-Fixed -Text 'USER'    -Width $headerUserWidth) +
        (Format-Fixed -Text 'STATE'   -Width $c.State) +
        (Format-Fixed -Text 'SESSION' -Width $c.WinStation) +
        (Format-Fixed -Text 'ID'      -Width $c.SessionId) +
        (Format-Fixed -Text 'IDLE'    -Width $c.Idle) +
        'LOGON'
    )
    $headerPadded = Format-Fixed -Text $headerText -Width $inner
    Write-AnsiLine (
        $p.BorderBright + $b.V +
        $p.Bold + $p.Header + $headerPadded + $p.Reset +
        $p.BorderBright + $b.V
    )

    Write-AnsiLine ($p.BorderBright + $b.TJL + ($b.H * $inner) + $b.TJR)

    # --- Session rows --------------------------------------------------------
    $sorted = Get-SortedSessionsForDisplay -Sessions $Sessions

    foreach ($session in $sorted) {
        Write-AnsiLine (Format-SessionRow -Session $session -InnerWidth $inner)
    }

    Write-AnsiLine ($p.BorderBright + $b.BL + ($b.H * $inner) + $b.BR)
}

function Format-SessionRow {
    param($Session, [int]$InnerWidth)

    $p = $script:Palette
    $b = $script:Box

    $isActive   = $Session.State -eq [LISSTech.Wts.WtsConnectState]::Active
    $isDisabled = [bool]$Session.IsUserDisabled

    # Mark glyph + color: star for caller's own session, filled circle for
    # active, open circle for disconnected or anything else.
    if ($Session.IsCurrent) {
        $mark      = '★'
        $markColor = $p.Current
    } elseif ($isActive) {
        $mark      = '●'
        $markColor = $p.ActiveBright
    } else {
        $mark      = '○'
        $markColor = $p.DiscBright
    }

    $stateColor = if ($isActive)   { $p.Active }   else { $p.Disc }
    $userColor  = if ($isDisabled) { $p.Error }    else { $p.Username }

    $winStation = if ([string]::IsNullOrWhiteSpace($Session.WinStation)) {
        '-'
    } else {
        $Session.WinStation
    }

    $idleText  = Format-IdleSpan -Span $Session.IdleTime
    $idleColor = if ($Session.IdleTime.TotalDays -ge 7) { $p.IdleHot } else { $p.IdleDim }

    $logonText = if ($null -eq $Session.LogonTime) {
        'unknown'
    } else {
        $Session.LogonTime.ToString('M/d/yyyy h:mm tt')
    }

    # Column-width ledger (visible chars only):
    #   leading space           = 1
    #   mark + space            = 2
    #   username (fixed 20+2sp) = 22
    #   state (fixed 7)         =  7
    #   winstation (fixed 14)   = 14
    #   session id (fixed 9)    =  9
    #   idle (fixed 15)         = 15
    #   logon (fixed 19)        = 19
    #   disabled badge optional = 11 when present (' ⚠ DISABLED')
    #   ------------------------------------------------
    #   minimum body            = 89
    #   with badge              = 100
    # InnerWidth is PanelWidth - 2 = 94, so the badge pushes us 6 over.
    # We truncate logon to 13 chars when a badge is present — enough for
    # "4/22/2026 11:" which is unambiguous. Non-disabled rows get full
    # 19-char logon like "4/22/2026 11:24 PM".
    $logonWidth = if ($isDisabled) { $script:Col.LogonShort } else { $script:Col.LogonFull }

    $disabledBadge = if ($isDisabled) {
        ' ' + $p.Error + '⚠ DISABLED' + $p.Reset
    } else {
        ''
    }

    $c = $script:Col
    $body = (
        ' ' +
        $markColor    + $mark + $p.Reset + ' ' +
        $userColor    + (Format-Fixed -Text $Session.Username -Width $c.Username) + $p.Reset + (' ' * $c.UserGap) +
        $stateColor   + (Format-Fixed -Text (Format-State $Session.State) -Width $c.State) + $p.Reset +
        $p.WinStation + (Format-Fixed -Text $winStation -Width $c.WinStation) + $p.Reset +
        $p.SessionId  + (Format-Fixed -Text "id$($Session.SessionId)" -Width $c.SessionId) + $p.Reset +
        $idleColor    + (Format-Fixed -Text $idleText -Width $c.Idle) + $p.Reset +
        $p.Logon      + (Format-Fixed -Text $logonText -Width $logonWidth) + $p.Reset +
        $disabledBadge
    )

    $padding = $InnerWidth - (Get-VisibleLength $body)
    if ($padding -lt 0) { $padding = 0 }

    $p.BorderBright + $b.V + $body + (' ' * $padding) + $p.BorderBright + $b.V
}

# ============================================================================
# Status bar (footer panel)
# ============================================================================

function Write-StatusBar {
    param(
        [int]$Scanned,
        [int]$WithSessions,
        [int]$Total,
        [int]$Active,
        [int]$Disc,
        [int]$Other,
        [int]$Unique,
        [int]$Disabled,
        [int]$Offline,
        [object[]]$Errored = @(),
        [TimeSpan]$Elapsed
    )

    $p = $script:Palette
    $b = $script:Box
    $inner = $script:PanelWidth - 2

    Write-Blank
    Write-AnsiLine ($p.BorderBright + $b.TL + ($b.H * $inner) + $b.TR)

    # Line 1 — headline stats
    $headline = (
        ' ' +
        $p.Bold + $p.TitleFg + 'SUMMARY' + $p.Reset + '  ' +
        $p.TitleDim + ('{0} servers · {1} with sessions · {2:N1}s' -f $Scanned, $WithSessions, $Elapsed.TotalSeconds) + $p.Reset
    )
    $pad = $inner - (Get-VisibleLength $headline)
    if ($pad -lt 0) { $pad = 0 }
    Write-AnsiLine ($p.BorderBright + $b.V + $headline + (' ' * $pad) + $p.BorderBright + $b.V)

    # Line 2 — chips
    $chips = @()

    $buildChip = {
        param($Color, $Glyph, $Count, $Label)
        $Color + $Glyph + $p.Reset + ' ' + $p.Username + $Count + $p.Reset + ' ' + $p.TitleDim + $Label + $p.Reset
    }

    $chips += & $buildChip $p.Active  '●' $Active 'active'
    $chips += & $buildChip $p.Disc    '○' $Disc   'disconnected'

    if ($Other -gt 0) { $chips += & $buildChip $p.IdleDim '·' $Other 'other' }
    if ($Disabled -gt 0) { $chips += & $buildChip $p.Error '⚠' $Disabled 'disabled' }
    $chips += & $buildChip $p.Info    '◆' $Unique 'users'
    if ($Offline -gt 0) { $chips += & $buildChip $p.IdleDim '·' $Offline 'offline' }
    if ($Errored.Count -gt 0) {
        $chips += & $buildChip $p.Error '✗' $Errored.Count 'errored'
    }

    $chipLine = ' ' + ($chips -join '   ')
    $pad = $inner - (Get-VisibleLength $chipLine)
    if ($pad -lt 0) { $pad = 0 }
    Write-AnsiLine ($p.BorderBright + $b.V + $chipLine + (' ' * $pad) + $p.BorderBright + $b.V)

    Write-AnsiLine ($p.BorderBright + $b.BL + ($b.H * $inner) + $b.BR)

    # Error detail below the panel, grouped by message so one RPC outage
    # renders as one line instead of N identical repetitions.
    if ($Errored.Count -gt 0) {
        Write-Blank
        $grouped = $Errored | Group-Object Error | Sort-Object Count -Descending
        foreach ($group in $grouped) {
            $hostList = ($group.Group | Select-Object -ExpandProperty Server | Sort-Object) -join ', '
            $line1 = '  ' + $p.Error + '✗ ' + $p.Reset + $p.TitleFg + $group.Name + $p.Reset
            $line2 = '    ' + $p.TitleDim + "[$($group.Count)] $hostList" + $p.Reset
            Write-AnsiLine $line1
            Write-AnsiLine $line2
        }
    }

    Write-Blank
}

function Write-EmptyState {
    Write-Blank
    Write-AnsiLine ('  ' + $script:Palette.TitleDim + '(no matching sessions)' + $script:Palette.Reset)
    Write-Blank
}

# ============================================================================
# Async logoff view
# ============================================================================

$script:LogoffWorker = {
    param($target, $queue)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $hServer = [IntPtr]::Zero
    $isLoggedOff = $false
    $errMsg = $null

    try {
        $hServer = [LISSTech.Wts.Native]::WTSOpenServerW($target.Server)
        $isLoggedOff = [LISSTech.Wts.Native]::WTSLogoffSession($hServer, $target.SessionId, $true)
        if (-not $isLoggedOff) {
            $code   = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $errMsg = '{0} ({1})' -f (New-Object System.ComponentModel.Win32Exception($code)).Message, $code
        }
    } catch {
        $errMsg = $_.Exception.Message
    } finally {
        if ($hServer -ne [IntPtr]::Zero) {
            [LISSTech.Wts.Native]::WTSCloseServer($hServer)
        }
    }

    $sw.Stop()
    $queue.Enqueue([pscustomobject]@{
        Key       = $target.Key
        LoggedOff = $isLoggedOff
        Error     = $errMsg
        Elapsed   = $sw.Elapsed
    })
}

$script:LogoffCol = [ordered]@{
    PRI = 3; SERVER = 18; USER = 18; SESSION = 12; TASK = 22; ELAPSED = 7; RESULT = 30
}

function Format-LogoffHeaderRow {
    $p = $script:Palette
    $cells = foreach ($col in $script:LogoffCol.Keys) {
        $w = $script:LogoffCol[$col]
        $color = if ($col -eq 'SERVER') { $p.Warning } else { $p.Header }
        $color + (Format-Fixed -Text $col -Width $w) + $p.Reset
    }
    ' ' + ($cells -join ' ')
}

function Format-LogoffDividerRow {
    $p = $script:Palette
    $cells = foreach ($col in $script:LogoffCol.Keys) {
        $w = $script:LogoffCol[$col]
        $p.TitleDim + ('─' * $w) + $p.Reset
    }
    ' ' + ($cells -join ' ')
}

function Format-LogoffRow {
    <#
    .SYNOPSIS
        Flat row for the async logoff view. Columns:
          PRI SERVER USER SESSION TASK ELAPSED RESULT
        PRI: '  ' while running, '* ' (gold/scanner) never used here because
        the caller already excludes IsCurrent sessions. '!! ' when the row
        is a disabled-user session (surfaced for operator visibility).
        TASK: Cylon bar while running; solid bar on success; error text on fail.
    #>
    param($Target)

    $p = $script:Palette
    $W = $script:LogoffCol

    $elapsed = switch ($Target.Status) {
        'running' { [DateTime]::UtcNow - $Target.Started }
        default   { $Target.Elapsed }
    }

    # PRI gutter — disabled-user sessions still deserve a warning glyph
    $isDisabled = [bool]$Target.IsUserDisabled
    $priGlyph, $priColor = if ($isDisabled) { '!!', $p.Error } else { '  ', $p.TitleDim }

    # TASK column — Cylon bar while running, solid on OK, '—' on fail (error
    # goes in RESULT, not here, to avoid duplication).
    $taskColor, $taskText = switch ($Target.Status) {
        'running' {
            $bar = Format-CylonBar -ElapsedSec $elapsed.TotalSeconds
            @($p.Scanner, ('[' + $bar + ']'))
            break
        }
        'ok' {
            @($p.Success, ('[' + ('█' * $script:BarWidth) + ']'))
            break
        }
        'fail' {
            @($p.TitleDim, '—')
        }
    }

    # RESULT column — '—' while running, 'OK' on success, error text on fail
    $resultColor, $resultText = switch ($Target.Status) {
        'running' { @($p.TitleDim, '—'); break }
        'ok'      { @($p.Success,  'OK'); break }
        'fail'    {
            $err = if ($null -eq $Target.Error) { 'failed' } else { $Target.Error }
            @($p.Error, $err)
        }
    }

    $userColor  = if ($isDisabled) { $p.Error } else { $p.Username }
    $timeColor  = switch ($Target.Status) {
        'running' { $p.TitleDim }
        'ok'      { $p.Success }
        'fail'    { $p.Error }
    }
    $timeText = Format-Duration -Span $elapsed

    $cells = @(
        $priColor      + (Format-Fixed -Text $priGlyph   -Width $W.PRI)     + $p.Reset
        $p.Server      + (Format-Fixed -Text $Target.Server   -Width $W.SERVER)  + $p.Reset
        $userColor     + (Format-Fixed -Text $Target.Username -Width $W.USER)    + $p.Reset
        $p.WinStation  + (Format-Fixed -Text ("id$($Target.SessionId)") -Width $W.SESSION) + $p.Reset
        $taskColor     + (Format-Fixed -Text $taskText -Width $W.TASK)    + $p.Reset
        $timeColor     + (Format-Fixed -Text $timeText -Width $W.ELAPSED) + $p.Reset
        $resultColor   + (Format-Fixed -Text $resultText -Width $W.RESULT) + $p.Reset
    )
    ' ' + ($cells -join ' ')
}

function Start-AsyncLogoff {
    <#
    .SYNOPSIS
        Dispatches WTSLogoffSession calls in parallel and renders live,
        per-row progress docker-pull style.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Sessions,

        [ValidateRange(1, 128)]
        [int]$ThrottleLimit = 16
    )

    begin {
        Write-Debug "Start-AsyncLogoff → sessions=$($Sessions.Count) throttle=$ThrottleLimit"
    }

    end {
        if ($Sessions.Count -eq 0) { return }

        $p = $script:Palette

        # --- One-line header --------------------------------------------------
        $sessWord = if ($Sessions.Count -eq 1) { 'session' } else { 'sessions' }
        Write-Blank
        Write-AnsiLine (
            ' ' + $p.Bold + $p.Warning + 'LOGOFF' + $p.Reset +
            '  ' + $p.TitleDim + ('{0} {1}' -f $Sessions.Count, $sessWord) + $p.Reset
        )
        Write-AnsiLine (Format-LogoffHeaderRow)
        Write-AnsiLine (Format-LogoffDividerRow)

        # --- Build per-target state ------------------------------------------
        $targets = @()
        $index = 0
        foreach ($session in $Sessions) {
            $targets += [pscustomobject]@{
                Key            = $index
                Server         = $session.Server
                SessionId      = $session.SessionId
                Username       = $session.Username
                State          = $session.State
                IsUserDisabled = [bool]$session.IsUserDisabled
                Status         = 'running'
                Started        = [DateTime]::UtcNow
                Elapsed        = [TimeSpan]::Zero
                LoggedOff      = $false
                Error          = $null
            }
            $index++
        }

        # Reserve one line per target. Repaint loop scrolls back exactly
        # rowCount lines — no chrome below the rows.
        foreach ($target in $targets) {
            Write-AnsiLine (Format-LogoffRow -Target $target)
        }

        # --- Dispatch --------------------------------------------------------
        $queue = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
        $pool  = [runspacefactory]::CreateRunspacePool(1, [math]::Min($ThrottleLimit, $targets.Count))
        $pool.Open()

        $jobs = foreach ($target in $targets) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($script:LogoffWorker)
            [void]$ps.AddArgument($target)
            [void]$ps.AddArgument($queue)
            $target.Started = [DateTime]::UtcNow

            [pscustomobject]@{
                Pipe   = $ps
                Handle = $ps.BeginInvoke()
            }
        }

        $rowCount = $targets.Count
        $scrollUp = $rowCount   # no bottom chrome; scroll back exactly to first row

        try {
            # Repaint loop
            while (@($jobs | Where-Object { -not $_.Handle.IsCompleted }).Count -gt 0) {
                $evt = $null
                while ($queue.TryDequeue([ref]$evt)) {
                    $t = $targets[$evt.Key]
                    $t.Status    = if ($evt.LoggedOff) { 'ok' } else { 'fail' }
                    $t.LoggedOff = $evt.LoggedOff
                    $t.Error     = $evt.Error
                    $t.Elapsed   = $evt.Elapsed
                }

                $buffer = "$script:CSI$scrollUp`F"
                foreach ($t in $targets) {
                    $buffer += "$script:CSI" + '2K'
                    $buffer += (Format-LogoffRow -Target $t) + $p.Reset + "`n"
                }
                [Console]::Out.Write($buffer)

                Start-Sleep -Milliseconds 55
            }

            # Final drain
            $evt = $null
            while ($queue.TryDequeue([ref]$evt)) {
                $t = $targets[$evt.Key]
                $t.Status    = if ($evt.LoggedOff) { 'ok' } else { 'fail' }
                $t.LoggedOff = $evt.LoggedOff
                $t.Error     = $evt.Error
                $t.Elapsed   = $evt.Elapsed
            }

            $buffer = "$script:CSI$scrollUp`F"
            foreach ($t in $targets) {
                $buffer += "$script:CSI" + '2K'
                $buffer += (Format-LogoffRow -Target $t) + $p.Reset + "`n"
            }
            [Console]::Out.Write($buffer)
        } finally {
            foreach ($job in $jobs) {
                try { [void]$job.Pipe.EndInvoke($job.Handle) } catch {}
                $job.Pipe.Dispose()
            }
            $pool.Close()
            $pool.Dispose()
        }

        # --- Tally -----------------------------------------------------------
        $okTargets   = @($targets.Where({ $_.Status -eq 'ok' }))
        $failTargets = @($targets.Where({ $_.Status -eq 'fail' }))
        $okCount     = $okTargets.Count
        $failCount   = $failTargets.Count
        $skipCount   = 0  # AsyncLogoff doesn't skip; the caller filters out
                          # IsCurrent sessions before dispatching.

        Write-Blank
        Write-AnsiLine (
            '  ' +
            $p.Success + '✓ ' + $p.Username + $okCount   + $p.Reset + ' ' + $p.TitleDim + 'logged off' + $p.Reset +
            '   ' +
            $p.Error   + '✗ ' + $p.Username + $failCount + $p.Reset + ' ' + $p.TitleDim + 'failed'     + $p.Reset
        )

        if ($failCount -gt 0) {
            Write-Blank
            foreach ($failed in $failTargets) {
                $descr = '{0} on {1} (id {2})' -f $failed.Username, $failed.Server, $failed.SessionId
                Write-AnsiLine (
                    '  ' + $p.Error + '✗ ' + $p.Reset +
                    $p.Username + $descr + $p.Reset +
                    $p.TitleDim + ': ' + $failed.Error + $p.Reset
                )
            }
        }

        Write-Blank

        Write-Debug "Start-AsyncLogoff → ok=$okCount fail=$failCount"

        # Emit the result so callers (Show-UserSession with -Report) can
        # feed the logoff summary into the report generator.
        [pscustomobject]@{
            Succeeded = $okCount
            Failed    = $failCount
            Skipped   = $skipCount
            Failures  = @($failTargets | ForEach-Object {
                [pscustomobject]@{
                    Server    = $_.Server
                    Username  = $_.Username
                    SessionId = $_.SessionId
                    Error     = $_.Error
                }
            })
        }
    }
}
