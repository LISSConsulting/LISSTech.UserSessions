# -----------------------------------------------------------------------------
# ReportDispatch.ps1 — side effects.
#
# All the impure stuff (file IO, clipboard, browser launch) lives here.
# Renderers stay pure functions; this is the shell that turns their
# output into real-world effects.
#
# Separating this from rendering means tests can exercise the full
# renderer stack without touching the filesystem or user's clipboard.
# -----------------------------------------------------------------------------

function Set-ClipboardHtml {
    <#
    .SYNOPSIS
        Writes an HTML fragment to the Windows clipboard as CF_HTML so
        it pastes as RENDERED content into HaloPSA / Outlook / Word.

        Clipboard APIs require an STA thread. Windows PowerShell 5.1 is
        STA by default; PowerShell 7+ is MTA by default, so we detect
        and dispatch to a dedicated STA thread when needed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Html
    )

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

    $apartmentState = [System.Threading.Thread]::CurrentThread.ApartmentState

    if ($apartmentState -eq [System.Threading.ApartmentState]::STA) {
        [System.Windows.Forms.Clipboard]::SetText(
            $Html,
            [System.Windows.Forms.TextDataFormat]::Html
        )
        return
    }

    $thread = [System.Threading.Thread]::new([System.Threading.ThreadStart]{
        [System.Windows.Forms.Clipboard]::SetText(
            $Html,
            [System.Windows.Forms.TextDataFormat]::Html
        )
    })
    $thread.SetApartmentState([System.Threading.ApartmentState]::STA)
    $thread.Start()
    $thread.Join()
}

function Resolve-ReportClipboardDecision {
    <#
    .SYNOPSIS
        Pure function deciding whether to copy to clipboard, given the
        format and argument state. Extracted so the decision can be
        tested without touching the clipboard.

    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('markdown','html')]
        [string]$Format,

        [bool]$ClipboardExplicit,
        [bool]$ClipboardOn,
        [bool]$HasReportPath
    )

    if ($Format -eq 'markdown') {
        if ($ClipboardExplicit) { return $ClipboardOn }
        return (-not $HasReportPath)
    }

    if ($Format -eq 'html') {
        if ($ClipboardExplicit) { return $ClipboardOn }
        return (-not $HasReportPath)
    }

    $false
}

function Resolve-ReportFilePath {
    <#
    .SYNOPSIS
        Pure function picking the effective file path. Returns $null when
        nothing should be written to disk (markdown without -ReportPath).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('markdown','html')]
        [string]$Format,

        [string]$ReportPath
    )

    if ($ReportPath) { return $ReportPath }
    if ($Format -eq 'html') {
        return (Join-Path $env:TEMP ("UserSession-Report-{0:yyyyMMdd-HHmmss}.html" -f (Get-Date)))
    }
    $null
}

function Invoke-ReportDispatch {
    <#
    .SYNOPSIS
        Dispatches rendered content to file / clipboard / browser per
        format and argument state.

        Markdown:
          - Default: plain-text clipboard
          - -ReportPath X: file only (no clipboard unless -Clipboard too)
        HTML:
          - Default: temp file + CF_HTML clipboard + browser preview
          - -ReportPath X: file only (silent attachment mode)
          - -Clipboard:$false: suppresses clipboard
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('markdown','html')]
        [string]$Format,

        [Parameter(Mandatory)]
        [string]$Content,

        [string]$ReportPath,
        [switch]$Clipboard
    )

    $wroteFile     = $false
    $copiedToClip  = $false
    $browserOpened = $false
    $effectivePath = Resolve-ReportFilePath -Format $Format -ReportPath $ReportPath

    # ---- File write ----
    if ($effectivePath) {
        try {
            $dir = Split-Path -Parent $effectivePath
            if ($dir -and -not (Test-Path $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            [System.IO.File]::WriteAllText(
                $effectivePath,
                $Content,
                (New-Object System.Text.UTF8Encoding $true)
            )
            $wroteFile = $true
            Write-Verbose "Report written to: $effectivePath"
        } catch {
            Write-Warning "Failed to write report to '$effectivePath': $($_.Exception.Message)"
        }
    }

    # ---- Clipboard ----
    $clipboardExplicit = $PSBoundParameters.ContainsKey('Clipboard')
    $clipboardOn       = [bool]$Clipboard
    $decisionArgs = @{
        Format            = $Format
        ClipboardExplicit = $clipboardExplicit
        ClipboardOn       = $clipboardOn
        HasReportPath     = [bool]$ReportPath
    }
    $shouldClipboard = Resolve-ReportClipboardDecision @decisionArgs

    Write-Debug "Invoke-ReportDispatch → Format=$Format ReportPath='$ReportPath' explicit=$clipboardExplicit on=$clipboardOn → $shouldClipboard"

    if ($shouldClipboard) {
        try {
            if ($Format -eq 'html') {
                Set-ClipboardHtml -Html $Content
            } else {
                Set-Clipboard -Value $Content
            }
            $copiedToClip = $true
        } catch {
            Write-Warning "Failed to copy to clipboard: $($_.Exception.Message)"
        }
    }

    # ---- Browser preview (HTML, no explicit path only) ----
    if ($Format -eq 'html' -and $wroteFile -and -not $ReportPath) {
        try {
            Start-Process $effectivePath | Out-Null
            $browserOpened = $true
        } catch {
            Write-Warning "Failed to open browser: $($_.Exception.Message)"
        }
    }

    # ---- User-visible status ----
    $bits = @()
    if ($copiedToClip)  { $bits += 'copied to clipboard' }
    if ($wroteFile)     { $bits += "saved to $effectivePath" }
    if ($browserOpened) { $bits += 'opened in browser' }
    if ($bits.Count -gt 0) {
        $p = $script:Palette
        Write-AnsiLine ('  ' + $p.Success + '✓ Report: ' + $p.Reset + $p.TitleFg + ($bits -join ' · ') + $p.Reset)
    }

    # ---- Structured result for callers ----
    [pscustomobject]@{
        Format        = $Format
        FilePath      = if ($wroteFile) { $effectivePath } else { $null }
        Clipboard     = $copiedToClip
        BrowserOpened = $browserOpened
    }
}
