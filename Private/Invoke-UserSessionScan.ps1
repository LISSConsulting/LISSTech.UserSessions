function Invoke-UserSessionScan {
    <#
    .SYNOPSIS
        Shared scan orchestrator: resolves users and computers, filters for
        reachability, fans out WTS enumeration via a RunspacePool, and
        returns an aggregate result object.

    .DESCRIPTION
        AD lookups use System.DirectoryServices.DirectorySearcher so the
        module has no dependency on the ActiveDirectory RSAT module.

        Disabled users are resolved alongside the user filter and passed
        to the scan workers so each emitted session carries an
        IsUserDisabled flag. This surfaces stale sessions for offboarded
        or compromised accounts, which is a primary use case of this
        module — disabling an AD account does not tear down the user's
        existing Kerberos session.
    #>
    [CmdletBinding()]
    param(
        [string[]]$UserSearchBase,
        [string[]]$Username,
        [string[]]$ComputerName,
        [string]  $ComputerLdapFilter     = '',

        [ValidateRange(1, 128)]
        [int]     $ThrottleLimit         = 16,

        [ValidateRange(100, 30000)]
        [int]     $PingTimeoutMs         = 2000,

        [switch]  $SkipConnectivityCheck,
        [string]  $ProgressActivityPrefix = ''
    )

    begin {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Write-Debug 'Invoke-UserSessionScan → entering'
        Write-Debug "  UserSearchBase=$($UserSearchBase.Count) Username=$($Username.Count) ComputerName=$($ComputerName.Count)"
        Write-Debug "  ComputerLdapFilter='$ComputerLdapFilter' SkipConnectivityCheck=$SkipConnectivityCheck Throttle=$ThrottleLimit"
    }

    end {
        # -- Resolve users + disabled users from the directory ----------------
        $resolvedUsers    = [System.Collections.Generic.List[string]]::new()
        $disabledNames    = [System.Collections.Generic.List[string]]::new()

        if ($UserSearchBase) {
            foreach ($ou in $UserSearchBase) {
                try {
                    foreach ($entry in (Search-DirectoryUser -SearchBase $ou)) {
                        [void]$resolvedUsers.Add($entry.Sam)
                        if ($entry.IsDisabled) { [void]$disabledNames.Add($entry.Sam) }
                    }
                } catch {
                    Write-Warning "OU unreachable: $ou — $($_.Exception.Message)"
                }
            }
        }

        if ($Username) {
            foreach ($name in $Username) { [void]$resolvedUsers.Add($name) }
        }

        # Known-users filter (applied in the scan worker to skip unmatched
        # sessions). Null means "no filter — include every session".
        $userSet = $null
        if ($resolvedUsers.Count -gt 0) {
            $userSet = New-Object 'System.Collections.Generic.HashSet[string]' (
                [string[]]$resolvedUsers,
                [System.StringComparer]::OrdinalIgnoreCase
            )
        }

        # Disabled-users lookup (used to annotate, never to filter). Passed
        # as an empty set rather than null so workers can unconditionally
        # call .Contains() without a null check.
        $disabledSet = New-Object 'System.Collections.Generic.HashSet[string]' (
            [string[]]$disabledNames,
            [System.StringComparer]::OrdinalIgnoreCase
        )

        Write-Debug "Invoke-UserSessionScan → users=$($resolvedUsers.Count) disabled=$($disabledSet.Count)"

        # -- Resolve computers ------------------------------------------------
        $computers = switch ($null -ne $ComputerName -and $ComputerName.Count -gt 0) {
            $true {
                @($ComputerName | ForEach-Object { [pscustomobject]@{ Name = $_ } })
            }
            $false {
                $searchParams = @{}
                if ($ComputerLdapFilter) { $searchParams.Filter = $ComputerLdapFilter }

                try {
                    @(Search-DirectoryComputer @searchParams | Sort-Object Name)
                } catch {
                    Write-Warning "Directory search failed: $($_.Exception.Message)"
                    @()
                }
            }
        }

        Write-Debug "Invoke-UserSessionScan → resolved $($computers.Count) computer(s)"

        if ($computers.Count -eq 0) {
            Write-Debug 'Invoke-UserSessionScan → no computers, returning empty'
            return [pscustomobject]@{
                Sessions       = @()
                Users          = $resolvedUsers.Count
                DisabledUsers  = $disabledSet.Count
                Offline        = @()
                Errored        = @()
                Scanned        = 0
                Elapsed        = $stopwatch.Elapsed
            }
        }

        # -- Connectivity sweep -----------------------------------------------
        $offlineComputers = @()

        if (-not $SkipConnectivityCheck) {
            Write-Debug 'Invoke-UserSessionScan → running connectivity sweep'

            $pingCounter = New-Object 'System.Collections.Concurrent.ConcurrentBag[int]'
            $pingParams = @{
                InputObject      = $computers
                ScriptBlock      = $script:PingScript
                SharedArgs       = @($PingTimeoutMs, $pingCounter)
                ThrottleLimit    = 32
                ProgressActivity = ($ProgressActivityPrefix + 'Pinging hosts')
                ProgressCounter  = $pingCounter
            }
            $pingResults = @(Invoke-RunspaceBatch @pingParams)

            $computers = @(
                $pingResults |
                    Where-Object Online |
                    Select-Object -ExpandProperty Server |
                    Sort-Object Name
            )
            $offlineComputers = @(
                $pingResults |
                    Where-Object { -not $_.Online } |
                    Select-Object -ExpandProperty Server |
                    Sort-Object Name
            )

            Write-Debug "Invoke-UserSessionScan → online=$($computers.Count) offline=$($offlineComputers.Count)"
        }

        if ($computers.Count -eq 0) {
            Write-Debug 'Invoke-UserSessionScan → no reachable computers'
            return [pscustomobject]@{
                Sessions       = @()
                Users          = $resolvedUsers.Count
                DisabledUsers  = $disabledSet.Count
                Offline        = $offlineComputers
                Errored        = @()
                Scanned        = 0
                Elapsed        = $stopwatch.Elapsed
            }
        }

        # -- Session scan -----------------------------------------------------
        Write-Debug "Invoke-UserSessionScan → enumerating sessions on $($computers.Count) host(s)"

        $scanCounter    = New-Object 'System.Collections.Concurrent.ConcurrentBag[int]'
        $localMachine   = [Environment]::MachineName
        $localUser      = [Environment]::UserName
        $localSessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId

        $scanParams = @{
            InputObject      = $computers
            ScriptBlock      = $script:ScanScript
            SharedArgs       = @($userSet, $disabledSet, $scanCounter, $localMachine, $localUser, $localSessionId)
            ThrottleLimit    = $ThrottleLimit
            ProgressActivity = ($ProgressActivityPrefix + 'Enumerating WTS sessions')
            ProgressCounter  = $scanCounter
        }
        $results = @(Invoke-RunspaceBatch @scanParams)

        $allSessions = @($results | ForEach-Object { $_.Sessions })
        $scanErrors  = @($results | Where-Object Error)

        $stopwatch.Stop()
        Write-Debug "Invoke-UserSessionScan → sessions=$($allSessions.Count) errors=$($scanErrors.Count) elapsed=$($stopwatch.Elapsed.TotalSeconds)s"

        [pscustomobject]@{
            Sessions       = $allSessions
            Users          = $resolvedUsers.Count
            DisabledUsers  = $disabledSet.Count
            Offline        = $offlineComputers
            Errored        = $scanErrors
            Scanned        = $computers.Count
            Elapsed        = $stopwatch.Elapsed
        }
    }
}
