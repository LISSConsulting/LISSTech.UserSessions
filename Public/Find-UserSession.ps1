function Find-UserSession {
    <#
    .SYNOPSIS
        Enumerates Windows Terminal Services user sessions and emits them as
        objects.

    .DESCRIPTION
        Queries each target server via WTSEnumerateSessions and emits one
        object per matching session. Target servers come from -ComputerName
        or, if omitted, from Active Directory via -ServerLdapFilter.
        Session results can be filtered by -Username or -UserSearchBase; if
        neither is specified, every session on every reachable server is
        returned.

        Output objects carry the LISSTech.UserSessions type name and expose
        Server, SessionId, Username, Domain, WinStation, State (enum),
        LogonTime (DateTime), LastInputTime (DateTime), IdleTime (TimeSpan),
        and IsCurrent. They bind directly to Stop-UserSession.

    .PARAMETER UserSearchBase
        Distinguished names of AD OUs whose users should be included in the
        filter set. Combines with -Username (set union).

    .PARAMETER Username
        Explicit SAM account names to filter sessions by.

    .PARAMETER ComputerName
        Explicit computer names to scan. If omitted, all enabled
        computers are discovered from Active Directory via LDAP.

    .PARAMETER ComputerLdapFilter
        Optional LDAP filter fragment to narrow AD discovery. Default is
        empty, meaning every enabled computer in the domain. Pass
        '(operatingSystem=*Windows*Server*)' to restrict to servers.

    .PARAMETER ThrottleLimit
        Maximum concurrent server scans.

    .PARAMETER PingTimeoutMs
        Per-host ping timeout for the connectivity sweep.

    .PARAMETER SkipConnectivityCheck
        Skip the ping-based reachability filter and attempt enumeration on
        every target. Useful when ICMP is blocked but WTS RPC is open.

    .EXAMPLE
        Find-UserSession -ComputerName SRV1

    .EXAMPLE
        Find-UserSession -Username marcin, amanda | Sort-Object IdleTime -Descending

    .EXAMPLE
        Find-UserSession |
            Where-Object IdleTime -gt (New-TimeSpan -Days 30) |
            Export-Csv stale.csv -NoTypeInformation

    .OUTPUTS
        LISSTech.UserSessions
    #>
    [CmdletBinding()]
    [OutputType('LISSTech.UserSessions.Session')]
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

        [switch]$SkipConnectivityCheck
    )

    begin {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $emittedCount = 0

        Write-Debug 'Find-UserSession → begin'
        Write-Debug "  UserSearchBase=$($UserSearchBase.Count) Username=$($Username.Count) ComputerName=$($ComputerName.Count)"
    }

    process {
        $scanParams = @{
            UserSearchBase        = $UserSearchBase
            Username              = $Username
            ComputerName          = $ComputerName
            ComputerLdapFilter    = $ComputerLdapFilter
            ThrottleLimit         = $ThrottleLimit
            PingTimeoutMs         = $PingTimeoutMs
            SkipConnectivityCheck = $SkipConnectivityCheck
        }
        $scan = Invoke-UserSessionScan @scanParams

        foreach ($err in $scan.Errored) {
            Write-Warning "$($err.Server): $($err.Error)"
        }

        foreach ($session in $scan.Sessions) {
            $emittedCount++
            $session
        }
    }

    end {
        $stopwatch.Stop()
        Write-Debug "Find-UserSession → end (emitted $emittedCount in $('{0:N1}' -f $stopwatch.Elapsed.TotalSeconds)s)"
    }
}
