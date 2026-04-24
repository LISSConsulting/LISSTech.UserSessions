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

# ============================================================================
# ClipboardBridge: pure-C# helper for PS7 MTA clipboard access.
#
# On PS7 the default apartment is MTA, but [Windows.Forms.Clipboard] requires
# STA. Running a PowerShell scriptblock on a bare STA thread fails because
# the thread has no attached runspace. Solution: emit a C# class whose
# ThreadStart is a pure CLR delegate — no PowerShell on the worker thread,
# so no runspace required. Idempotent across re-imports.
#
# The bridge sets multi-format clipboard data (CF_HTML + CF_UNICODETEXT) via
# DataObject so paste targets pick what they understand: rich-text editors
# get CF_HTML and render it; plain-text editors fall back to UnicodeText.
# ============================================================================

if (-not ('LISSTech.UserSessions.ClipboardBridge' -as [type]) -or
    -not ('LISSTech.UserSessions.ClipboardBridge' -as [type]).GetMethod('SetRich')) {
    try {
        Add-Type -ReferencedAssemblies System.Windows.Forms, System.Threading.Thread -TypeDefinition @'
using System;
using System.Threading;
using System.Windows.Forms;

namespace LISSTech.UserSessions {
    public static class ClipboardBridge {
        public static void SetRich(string cfHtml, string plainText) {
            Exception captured = null;
            Thread t = new Thread(delegate() {
                try {
                    DataObject data = new DataObject();
                    if (cfHtml != null)    data.SetData(DataFormats.Html,        cfHtml);
                    if (plainText != null) data.SetData(DataFormats.UnicodeText, plainText);
                    Clipboard.SetDataObject(data, true);
                } catch (Exception ex) {
                    captured = ex;
                }
            });
            t.SetApartmentState(ApartmentState.STA);
            t.Start();
            t.Join();
            if (captured != null) throw captured;
        }
    }
}
'@
    } catch {
        Write-Debug "ClipboardBridge Add-Type failed (type may already exist from a prior session — restart PowerShell to load updates): $($_.Exception.Message)"
    }
}

function ConvertTo-CfHtml {
    <#
    .SYNOPSIS
        Wraps an HTML document/fragment in the CF_HTML clipboard format
        with correct UTF-8 byte offsets in the header.

        CF_HTML requires:
          Version:0.9
          StartHTML:NNNNNNNNNN
          EndHTML:NNNNNNNNNN
          StartFragment:NNNNNNNNNN
          EndFragment:NNNNNNNNNN
          [full HTML with <!--StartFragment--> ... <!--EndFragment--> markers
           placed INSIDE <body>]

        Critical detail: the fragment bounds the body CONTENT, not the
        <html> shell. Word / Outlook / Chrome / most rich-text paste
        targets refuse fragments that contain <!DOCTYPE>, <html>, or
        <head> tags and fall back to plain-text — which is why we have
        to split around <body> and insert the markers there.

        Fragments without <body> (a bare HTML snippet like "<p>hi</p>")
        get wrapped in minimal <html><body> scaffolding.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Html)

    $startMark = '<!--StartFragment-->'
    $endMark   = '<!--EndFragment-->'

    # Split into pre-body / body-inner / post-body so we can place the
    # fragment markers inside <body>.
    $bodyOpen = [regex]::Match($Html, '<body\b[^>]*>', 'IgnoreCase')
    if ($bodyOpen.Success) {
        $bodyClose = [regex]::Match($Html, '</body\s*>', 'IgnoreCase')
        if ($bodyClose.Success -and $bodyClose.Index -gt ($bodyOpen.Index + $bodyOpen.Length)) {
            $preEnd = $bodyOpen.Index + $bodyOpen.Length
            $pre    = $Html.Substring(0, $preEnd)
            $inner  = $Html.Substring($preEnd, $bodyClose.Index - $preEnd)
            $post   = $Html.Substring($bodyClose.Index)
        } else {
            # <body> without a matching </body> — treat whole input as inner
            # and add a minimal closing shell so the CF_HTML is well-formed.
            $pre   = '<html><body>'
            $inner = $Html
            $post  = '</body></html>'
        }
    } else {
        $pre   = '<html><body>'
        $inner = $Html
        $post  = '</body></html>'
    }

    # Pull any <style> blocks out of the pre-body region (typically <head>)
    # and prepend them inside the fragment. Paste targets only see what's
    # between <!--StartFragment--> and <!--EndFragment--> — anything in
    # <head> gets dropped — so a styled report whose CSS lives in <head>
    # would paste unstyled. Browsers do this same lift when you Ctrl+A
    # → copy out of a preview window.
    $styleMatches = [regex]::Matches($pre, '<style\b[^>]*>[\s\S]*?</style\s*>', 'IgnoreCase')
    if ($styleMatches.Count -gt 0) {
        $styles = ($styleMatches | ForEach-Object { $_.Value }) -join "`n"
        $inner  = $styles + $inner
    }

    $utf8 = [System.Text.Encoding]::UTF8
    $headerTemplate = "Version:0.9`r`nStartHTML:{0:D10}`r`nEndHTML:{1:D10}`r`nStartFragment:{2:D10}`r`nEndFragment:{3:D10}`r`n"
    $headerLen = $utf8.GetByteCount(($headerTemplate -f 0, 0, 0, 0))

    # Byte offsets into the final payload:
    #   [header][pre]<!--StartFragment-->[inner]<!--EndFragment-->[post]
    # StartFragment points at the first byte AFTER <!--StartFragment-->.
    # EndFragment   points at the first byte OF  <!--EndFragment-->.
    $startHtml     = $headerLen
    $afterPre      = $startHtml + $utf8.GetByteCount($pre)
    $startFragment = $afterPre + $utf8.GetByteCount($startMark)
    $endFragment   = $startFragment + $utf8.GetByteCount($inner)
    $afterEndMark  = $endFragment + $utf8.GetByteCount($endMark)
    $endHtml       = $afterEndMark + $utf8.GetByteCount($post)

    ($headerTemplate -f $startHtml, $endHtml, $startFragment, $endFragment) +
    $pre + $startMark + $inner + $endMark + $post
}

function Set-ClipboardHtml {
    <#
    .SYNOPSIS
        Writes rich content to the Windows clipboard as CF_HTML (rendered
        paste into HaloPSA / Outlook / Word) plus an optional plain-text
        fallback (CF_UNICODETEXT) for editors that don't speak CF_HTML.

        Clipboard APIs require an STA thread. Windows PowerShell 5.1 is
        STA by default; PowerShell 7+ is MTA by default, so we detect
        and dispatch to a dedicated STA thread when needed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Html,
        [string]$PlainText
    )

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

    $cfHtml = ConvertTo-CfHtml -Html $Html
    $apartmentState = [System.Threading.Thread]::CurrentThread.ApartmentState

    if ($apartmentState -eq [System.Threading.ApartmentState]::STA) {
        $data = New-Object System.Windows.Forms.DataObject
        $data.SetData([System.Windows.Forms.DataFormats]::Html, $cfHtml)
        if ($PlainText) {
            $data.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $PlainText)
        }
        [System.Windows.Forms.Clipboard]::SetDataObject($data, $true)
        return
    }

    $bridge = 'LISSTech.UserSessions.ClipboardBridge' -as [type]
    if (-not $bridge -or -not $bridge.GetMethod('SetRich')) {
        throw [System.PlatformNotSupportedException]::new(
            'HTML clipboard unavailable: Windows Forms runtime (Microsoft.WindowsDesktop.App) not present in this PowerShell edition.')
    }
    [LISSTech.UserSessions.ClipboardBridge]::SetRich($cfHtml, $PlainText)
}

function Resolve-ReportClipboardDecision {
    <#
    .SYNOPSIS
        Pure function deciding whether to copy to clipboard. Extracted so
        the decision can be tested without touching the clipboard.

        Default behavior: clipboard ON unless -ReportPath was supplied
        (silent attachment mode). Explicit -Clipboard / -Clipboard:$false
        overrides the default in either direction.

    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    param(
        [bool]$ClipboardExplicit,
        [bool]$ClipboardOn,
        [bool]$HasReportPath
    )

    if ($ClipboardExplicit) { return $ClipboardOn }
    -not $HasReportPath
}

function Resolve-ReportFilePath {
    <#
    .SYNOPSIS
        Pure function picking the effective file path. Returns the user-
        supplied path verbatim if given, otherwise a timestamped temp-dir
        path so the browser preview has something to open.
    #>
    [CmdletBinding()]
    param([string]$ReportPath)

    if ($ReportPath) { return $ReportPath }
    Join-Path $env:TEMP ("UserSession-Report-{0:yyyyMMdd-HHmmss}.html" -f (Get-Date))
}

function Invoke-ReportDispatch {
    <#
    .SYNOPSIS
        Dispatches a rendered HTML report to file / clipboard / browser.

        Default: temp file + CF_HTML clipboard + browser preview.
        -ReportPath X:  file only at X (silent attachment mode).
        -Clipboard:$false: suppresses the clipboard.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [string]$ReportPath,
        [switch]$Clipboard
    )

    $wroteFile     = $false
    $copiedToClip  = $false
    $browserOpened = $false
    $effectivePath = Resolve-ReportFilePath -ReportPath $ReportPath

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
        ClipboardExplicit = $clipboardExplicit
        ClipboardOn       = $clipboardOn
        HasReportPath     = [bool]$ReportPath
    }
    $shouldClipboard = Resolve-ReportClipboardDecision @decisionArgs

    Write-Debug "Invoke-ReportDispatch → ReportPath='$ReportPath' explicit=$clipboardExplicit on=$clipboardOn → $shouldClipboard"

    if ($shouldClipboard) {
        try {
            Set-ClipboardHtml -Html $Content -PlainText $Content
            $copiedToClip = $true
        } catch {
            Write-Warning "Failed to copy to clipboard: $($_.Exception.Message)"
        }
    }

    # ---- Browser preview (only when no explicit path) ----
    if ($wroteFile -and -not $ReportPath) {
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
        FilePath      = if ($wroteFile) { $effectivePath } else { $null }
        Clipboard     = $copiedToClip
        BrowserOpened = $browserOpened
    }
}
