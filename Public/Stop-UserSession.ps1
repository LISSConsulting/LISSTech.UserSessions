function Stop-UserSession {
    <#
    .SYNOPSIS
        Logs off one or more Windows Terminal Services user sessions.

    .DESCRIPTION
        Calls WTSLogoffSession on the target server. Binds from the pipeline
        by property name, so session objects from Find-UserSession flow
        directly. Honors -WhatIf and -Confirm; ConfirmImpact is High, so
        -Confirm:$false is required for silent bulk logoff.

        The caller's own current session (IsCurrent=True on the input
        object) is skipped unconditionally as a safety measure.

    .PARAMETER ComputerName
        Target computer. Accepts pipeline input by property name from the
        'Server' property on LISSTech.UserSessions objects (alias Server).

    .PARAMETER SessionId
        Numeric session identifier. Accepts pipeline input by property name.

    .PARAMETER Username
        Optional; used only for display/log output.

    .PARAMETER State
        Optional; used only for display/log output.

    .PARAMETER IsCurrent
        If $true, the session is skipped. Set automatically from piped
        session objects so `Find | Stop` never targets the caller's own
        session.

    .PARAMETER PassThru
        Emit a LISSTech.UserSessions.LogoffResult for each processed target.

    .EXAMPLE
        Find-UserSession -Username marcin | Stop-UserSession -WhatIf

    .EXAMPLE
        Stop-UserSession -ComputerName RDS01 -SessionId 27 -Confirm:$false

    .EXAMPLE
        Find-UserSession |
            Where-Object { $_.State -eq 'Disconnected' -and $_.IdleTime.TotalDays -gt 7 } |
            Stop-UserSession -Confirm:$false -PassThru
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('LISSTech.UserSessions.LogoffResult')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [Alias('Server', 'Name')]
        [string]$ComputerName,

        [Parameter(Mandatory, Position = 1, ValueFromPipelineByPropertyName)]
        [int]$SessionId,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Username,

        [Parameter(ValueFromPipelineByPropertyName)]
        $State,

        [Parameter(ValueFromPipelineByPropertyName)]
        [bool]$IsCurrent,

        [switch]$PassThru
    )

    begin {
        $okCount   = 0
        $failCount = 0
        $skipCount = 0
        Write-Debug 'Stop-UserSession → begin'
    }

    process {
        if ($IsCurrent) {
            Write-Debug "  skip current session: $Username on $ComputerName (id $SessionId)"
            Write-Verbose "Skipping caller's own current session: $Username on $ComputerName (id $SessionId)"
            $skipCount++
            return
        }

        $userPart  = if ($Username) { $Username } else { '?' }
        $statePart = if ($State)    { ' ' + (Format-State $State) } else { '' }
        $description = '{0}{1} on {2} (session {3})' -f $userPart, $statePart, $ComputerName, $SessionId

        if (-not $PSCmdlet.ShouldProcess($description, 'WTSLogoffSession')) {
            return
        }

        $hServer = [IntPtr]::Zero
        $isLoggedOff = $false
        $errorText = $null

        try {
            $hServer = [LISSTech.Wts.Native]::WTSOpenServerW($ComputerName)
            $isLoggedOff = [LISSTech.Wts.Native]::WTSLogoffSession($hServer, $SessionId, $true)

            if (-not $isLoggedOff) {
                $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                $errorText = '{0} ({1})' -f (New-Object System.ComponentModel.Win32Exception($code)).Message, $code
                Write-Error "Failed to log off $description — $errorText"
            }
        } catch {
            $errorText = $_.Exception.Message
            Write-Error "Failed to log off $description — $errorText"
        } finally {
            if ($hServer -ne [IntPtr]::Zero) {
                [LISSTech.Wts.Native]::WTSCloseServer($hServer)
            }
        }

        if ($isLoggedOff) { $okCount++ } else { $failCount++ }

        if ($PassThru) {
            # Emit with property name "Server" to match the session-object
            # schema (LISSTech.UserSessions uses Server), so pipelines stay
            # consistent across Find → Stop → consumers.
            $result = [pscustomobject]@{
                Server    = $ComputerName
                SessionId = $SessionId
                Username  = $Username
                State     = $State
                LoggedOff = $isLoggedOff
                Error     = $errorText
            }
            $result.PSObject.TypeNames.Insert(0, 'LISSTech.UserSessions.LogoffResult')
            $result
        }
    }

    end {
        Write-Debug "Stop-UserSession → end (ok=$okCount fail=$failCount skipped=$skipCount)"
    }
}
