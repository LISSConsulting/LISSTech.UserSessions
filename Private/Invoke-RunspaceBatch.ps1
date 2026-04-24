function Invoke-RunspaceBatch {
    <#
    .SYNOPSIS
        Fan out a scriptblock across input items via a RunspacePool.

    .DESCRIPTION
        Each item is dispatched to its own runspace as the first positional
        argument to the scriptblock, followed by SharedArgs in order. All
        output is collected and returned.

        Optionally drives a Write-Progress bar from a ConcurrentBag[int] that
        workers .Add(1) to on completion.

    .OUTPUTS
        Whatever the scriptblock emits, flattened.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$InputObject,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [object[]]$SharedArgs = @(),

        [ValidateRange(1, 128)]
        [int]$ThrottleLimit = 16,

        [string]$ProgressActivity,

        [System.Collections.Concurrent.ConcurrentBag[int]]$ProgressCounter
    )

    begin {
        Write-Debug "Invoke-RunspaceBatch → items=$($InputObject.Count) throttle=$ThrottleLimit"
    }

    process {
        if (-not $InputObject -or $InputObject.Count -eq 0) {
            Write-Debug 'Invoke-RunspaceBatch → no items, returning'
            return
        }

        $pool = [runspacefactory]::CreateRunspacePool(1, $ThrottleLimit)
        $pool.Open()

        try {
            $jobs = foreach ($item in $InputObject) {
                $ps = [powershell]::Create()
                $ps.RunspacePool = $pool
                [void]$ps.AddScript($ScriptBlock)
                [void]$ps.AddArgument($item)
                foreach ($arg in $SharedArgs) {
                    [void]$ps.AddArgument($arg)
                }

                [pscustomobject]@{
                    Pipe   = $ps
                    Handle = $ps.BeginInvoke()
                }
            }

            if ($ProgressActivity -and $ProgressCounter) {
                $total = $InputObject.Count
                while (@($jobs | Where-Object { -not $_.Handle.IsCompleted }).Count -gt 0) {
                    $done = $ProgressCounter.Count
                    $progressParams = @{
                        Activity        = $ProgressActivity
                        Status          = "$done / $total"
                        PercentComplete = [math]::Min(100, ($done / $total) * 100)
                    }
                    Write-Progress @progressParams
                    Start-Sleep -Milliseconds 200
                }
                Write-Progress -Activity $ProgressActivity -Completed
            }

            foreach ($job in $jobs) {
                try {
                    $job.Pipe.EndInvoke($job.Handle)
                } catch {
                    Write-Warning "Runspace failed: $($_.Exception.Message)"
                } finally {
                    $job.Pipe.Dispose()
                }
            }
        } finally {
            $pool.Close()
            $pool.Dispose()
        }
    }

    end {
        Write-Debug 'Invoke-RunspaceBatch → complete'
    }
}
