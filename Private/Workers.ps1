# -----------------------------------------------------------------------------
# Worker scriptblocks dispatched by Invoke-RunspaceBatch.
#
# Stored in $script: scope so Invoke-UserSessionScan can reference them
# without hard-coding the scriptblock text at each call site.
# -----------------------------------------------------------------------------

Write-Debug 'Workers.ps1 → defining PingScript and ScanScript'

# ============================================================================
# Parallel reachability test (via System.Net.NetworkInformation.Ping, since
# Test-Connection -TimeoutSeconds does not exist on Windows PowerShell 5.1)
# ============================================================================

$script:PingScript = {
    param($server, $timeoutMs, $counter)

    $isOnline = $false
    $ping = $null
    try {
        $ping  = New-Object System.Net.NetworkInformation.Ping
        $reply = $ping.Send($server.Name, $timeoutMs)
        $isOnline = $reply.Status -eq 'Success'
    } catch {
        # Name resolution failure or host unreachable — treat as offline
    } finally {
        if ($ping) { $ping.Dispose() }
        [void]$counter.Add(1)
    }

    [pscustomobject]@{ Server = $server; Online = $isOnline }
}

# ============================================================================
# Parallel session enumeration (WTSEnumerateSessions + WTSQuerySessionInformation)
# ============================================================================

$script:ScanScript = {
    param($server, $knownUsers, $disabledUsers, $counter, $localMachine, $localUser, $localSessionId)

    $sessions = [System.Collections.Generic.List[object]]::new()
    $scanError = $null
    $hServer = [IntPtr]::Zero
    $ppSessionInfo = [IntPtr]::Zero

    try {
        $hServer = [LISSTech.Wts.Native]::WTSOpenServerW($server.Name)

        $sessionCount = 0
        $didEnumerate = [LISSTech.Wts.Native]::WTSEnumerateSessionsW(
            $hServer, 0, 1, [ref]$ppSessionInfo, [ref]$sessionCount)

        if (-not $didEnumerate) {
            $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            # Translate the common Win32 codes that WTS returns into something
            # a human can actually act on. Falls back to the system message
            # for unknown codes.
            $friendly = switch ($code) {
                5    { 'Access denied (not allowed to query sessions remotely)' }
                53   { 'Host unreachable (network path not found)' }
                203  { 'WTS service not reachable (RPC endpoint unavailable)' }
                1722 { 'WTS service not running on target host' }
                1726 { 'RPC call failed (host rebooting or firewalled)' }
                1727 { 'RPC endpoint mapper unreachable (firewall likely)' }
                default {
                    $sys = (New-Object System.ComponentModel.Win32Exception($code)).Message
                    "$sys (Win32 code $code)"
                }
            }
            throw $friendly
        }

        $structSize = [System.Runtime.InteropServices.Marshal]::SizeOf(
            [type][LISSTech.Wts.WTS_SESSION_INFO])
        $isServerLocal = $server.Name -ieq $localMachine

        for ($i = 0; $i -lt $sessionCount; $i++) {
            $basicPtr = [IntPtr]::Add($ppSessionInfo, $i * $structSize)
            $basic = [System.Runtime.InteropServices.Marshal]::PtrToStructure(
                $basicPtr, [type][LISSTech.Wts.WTS_SESSION_INFO])

            # Skip the services session (always id 0, no user)
            if ($basic.SessionId -eq 0) { continue }

            $infoPtr = [IntPtr]::Zero
            $infoBytes = 0

            $didQuery = [LISSTech.Wts.Native]::WTSQuerySessionInformationW(
                $hServer, $basic.SessionId,
                [LISSTech.Wts.WtsInfoClass]::SessionInfo,
                [ref]$infoPtr, [ref]$infoBytes)

            if (-not $didQuery -or $infoPtr -eq [IntPtr]::Zero) { continue }

            try {
                $info = [System.Runtime.InteropServices.Marshal]::PtrToStructure(
                    $infoPtr, [type][LISSTech.Wts.WTSINFO])

                $username = $info.UserName
                if ([string]::IsNullOrEmpty($username)) { continue }

                # Filter against the user set if one was provided
                if ($knownUsers -and -not $knownUsers.Contains($username)) { continue }

                $logonTime = $null
                if ($info.LogonTime -gt 0) {
                    $logonTime = [DateTime]::FromFileTime($info.LogonTime)
                }

                $currentTime = [DateTime]::Now
                if ($info.CurrentTime -gt 0) {
                    $currentTime = [DateTime]::FromFileTime($info.CurrentTime)
                }

                # Idle semantics differ by state:
                #   Disconnected → CurrentTime - DisconnectTime
                #   anything else → CurrentTime - LastInputTime
                $idle = [TimeSpan]::Zero
                $isDisc = $info.State -eq [LISSTech.Wts.WtsConnectState]::Disconnected
                if ($isDisc -and $info.DisconnectTime -gt 0) {
                    $idle = $currentTime - [DateTime]::FromFileTime($info.DisconnectTime)
                } elseif ($info.LastInputTime -gt 0) {
                    $idle = $currentTime - [DateTime]::FromFileTime($info.LastInputTime)
                }
                if ($idle -lt [TimeSpan]::Zero) { $idle = [TimeSpan]::Zero }

                $lastInputTime = $null
                if ($info.LastInputTime -gt 0) {
                    $lastInputTime = [DateTime]::FromFileTime($info.LastInputTime)
                }

                $isCurrent = $isServerLocal -and
                             ($username -ieq $localUser) -and
                             ($info.SessionId -eq $localSessionId)

                $isUserDisabled = $disabledUsers.Contains($username)

                $obj = [pscustomobject]@{
                    Server         = $server.Name
                    SessionId      = $info.SessionId
                    Username       = $username
                    Domain         = $info.Domain
                    WinStation     = $info.WinStationName
                    State          = $info.State
                    LogonTime      = $logonTime
                    LastInputTime  = $lastInputTime
                    IdleTime       = $idle
                    IsCurrent      = $isCurrent
                    IsUserDisabled = $isUserDisabled
                }
                $obj.PSObject.TypeNames.Insert(0, 'LISSTech.UserSessions.Session')
                [void]$sessions.Add($obj)
            } finally {
                [LISSTech.Wts.Native]::WTSFreeMemory($infoPtr)
            }
        }
    } catch {
        $scanError = $_.Exception.Message
    } finally {
        if ($ppSessionInfo -ne [IntPtr]::Zero) {
            [LISSTech.Wts.Native]::WTSFreeMemory($ppSessionInfo)
        }
        if ($hServer -ne [IntPtr]::Zero) {
            [LISSTech.Wts.Native]::WTSCloseServer($hServer)
        }
        [void]$counter.Add(1)
    }

    [pscustomobject]@{
        Server   = $server.Name
        Sessions = $sessions.ToArray()
        Error    = $scanError
    }
}
