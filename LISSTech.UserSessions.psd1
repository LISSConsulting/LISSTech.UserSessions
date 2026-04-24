@{
    RootModule           = 'LISSTech.UserSessions.psm1'
    ModuleVersion        = '26.114.4'
    GUID                 = '9de7e566-21a5-44b1-be2b-73add8bf3e4e'
    Author               = 'LISS Technologies'
    CompanyName          = 'LISS Consulting, Corp.'
    Copyright            = '(c) 2026 LISS Consulting, Corp. All rights reserved.'

    Description          = @'
Enumerate and manage Windows Terminal Services user sessions across your estate,
via the WTSEnumerateSessions Win32 API. Three cmdlets:

  Find-UserSession  : emits session objects (pipeline-friendly, scriptable)
  Show-UserSession  : renders a rich terminal report with async parallel logoff
                      and an optional ticket-ready HTML report
  Stop-UserSession  : pipeline-bound WTSLogoffSession wrapper

Designed for MSP maintenance-window workflows — scan a domain, filter sessions,
log them off in bulk with live progress, and drop a ticket-ready summary on
the clipboard. Works on Windows PowerShell 5.1 / Server 2016+ with no external
module dependencies (AD lookups use DirectorySearcher).
'@

    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport    = @(
        'Find-UserSession'
        'Show-UserSession'
        'Stop-UserSession'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    FileList             = @(
        'LISSTech.UserSessions.psd1'
        'LISSTech.UserSessions.psm1'
        'README.md'
        'LICENSE'
        'CHANGELOG.md'
        'profile-snippet.ps1'
        'Private\Types.ps1'
        'Private\Invoke-RunspaceBatch.ps1'
        'Private\Format-Display.ps1'
        'Private\Reporting\ReportStyles.ps1'
        'Private\Reporting\ReportModel.ps1'
        'Private\Reporting\ReportHtmlSections.ps1'
        'Private\Reporting\ReportHtml.ps1'
        'Private\Reporting\ReportDispatch.ps1'
        'Private\Workers.ps1'
        'Private\Search-Directory.ps1'
        'Private\Invoke-UserSessionScan.ps1'
        'Public\Find-UserSession.ps1'
        'Public\Show-UserSession.ps1'
        'Public\Stop-UserSession.ps1'
    )

    PrivateData = @{
        PSData = @{
            Tags         = @('TerminalServices', 'RDP', 'Sessions', 'MSP', 'WTS', 'LISSTech')
            LicenseUri   = 'https://github.com/LISSConsulting/LISSTech.UserSessions/blob/trunk/LICENSE'
            ProjectUri   = 'https://github.com/LISSConsulting/LISSTech.UserSessions'
            ReleaseNotes = @'
26.113.2 — Reporting subsystem refactor.
  * Reports now live in Private/Reporting/ split across 6 files:
    ReportModel     — view model + domain language
    ReportStyles    — palette + CSS in one place
    ReportHtmlSections — one pure function per section (OCP)
    ReportHtml      — composer (reads like a table of contents)
    ReportDispatch  — side effects (file, clipboard, browser)
  * New-ReportContext is the seam: presentation shape independent of
    scan result internals, so tests can inject synthetic data.
  * Resolve-ReportClipboardDecision + Resolve-ReportFilePath are pure
    functions — the dispatch logic is now unit-testable.
  * BDD Pester suite added under tests/ReportRendering.Tests.ps1
    with Given/When/Then for the behaviors that matter (format choice,
    section presence, scope description).
  * No user-facing behavior change.

26.113.1 — HTML reports paste as rendered content.
  * -Report html now copies the rendered HTML to the clipboard via
    the Windows CF_HTML clipboard format, so Ctrl+V into HaloPSA /
    Outlook / Word pastes the formatted report (tables, colors,
    borders, everything) — not raw HTML source.
  * Browser preview still opens by default. Pass -Clipboard:$false
    to suppress the clipboard write when you only want the preview.
  * New Private helper Set-ClipboardHtml with STA-thread dispatch
    for compatibility with PS 7 (MTA default).

26.113.0 — Plural rebrand, CalVer, GH-ready.
  * Module renamed LISSTech.UserSession → LISSTech.UserSessions.
  * Adopted CalVer (YY.DOY.patch) matching LISSTech.Billboard.
  * Emitted session object type renamed LISSTech.UserSession →
    LISSTech.UserSessions.Session for consistency.
  * Full GitHub repo scaffolding: README with badges + Mermaid diagrams,
    Apache 2.0 LICENSE, justfile with build/test/publish recipes,
    docs/ with brand assets, scripts/ with build utilities,
    tests/ with Pester skeleton, CLAUDE.md for AI pair-programming.
  * Cmdlet names remain singular (Find/Show/Stop-UserSession) per
    PowerShell's approved-verb + singular-noun convention. Existing
    scripts continue to work; only the module and type identities
    shifted to plural.

Prior history carried over from LISSTech.UserSession 1.0.0 through 1.5.0 —
see CHANGELOG.md for full detail.
'@
        }
    }
}
