#Requires -Version 5.1

# -----------------------------------------------------------------------------
# LISSTech.UserSessions loader
#
# Load order matters — files later in the list depend on things defined
# earlier. Conceptually:
#
#   Types          — P/Invoke registration (must be first)
#   Parallel       — runspace helpers
#   Display        — dashboard rendering + async logoff
#   Reporting      — view model, styles, renderers, dispatch
#                    (internal order: Model → Styles → Sections → Html/Markdown
#                    → Dispatch, since sections use Styles + Model helpers,
#                    composers use sections, dispatch uses the palette)
#   Workers        — scan worker scriptblocks
#   Search         — AD DirectorySearcher wrapper
#   Orchestrator   — the scan entry point
#   Public         — exported cmdlets last
# -----------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

$loadOrder = @(
    'Private\Types.ps1'
    'Private\Invoke-RunspaceBatch.ps1'
    'Private\Format-Display.ps1'

    # Reporting subsystem — order matters within the subfolder
    'Private\Reporting\ReportStyles.ps1'
    'Private\Reporting\ReportModel.ps1'
    'Private\Reporting\ReportHtmlSections.ps1'
    'Private\Reporting\ReportHtml.ps1'
    'Private\Reporting\ReportMarkdown.ps1'
    'Private\Reporting\ReportDispatch.ps1'

    'Private\Workers.ps1'
    'Private\Search-Directory.ps1'
    'Private\Invoke-UserSessionScan.ps1'

    'Public\Find-UserSession.ps1'
    'Public\Stop-UserSession.ps1'
    'Public\Show-UserSession.ps1'
)

foreach ($relative in $loadOrder) {
    $path = Join-Path -Path $PSScriptRoot -ChildPath $relative
    Write-Debug "LISSTech.UserSessions → loading $relative"
    . $path
}

Write-Debug 'LISSTech.UserSessions → module loaded'
