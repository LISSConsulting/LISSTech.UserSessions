# -----------------------------------------------------------------------------
# ReportHtml.ps1 — HTML report composition.
#
# This is the orchestrator. It takes the ReportContext and composes a
# document by calling the section renderers in order. Zero rendering
# logic lives here — everything delegated.
#
# Reading this file should tell you the shape of the document without
# having to understand HTML or CSS.
# -----------------------------------------------------------------------------

function Format-ReportHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context
    )

    $meta  = $Context.Meta
    $title = ConvertTo-HtmlSafe "Session Report — $($meta.Timestamp)"

    $sections = @(
        New-HtmlBannerSection       -Meta $meta
        New-HtmlMetaStripSection    -Meta $meta -Scope $Context.Scope
        New-HtmlLogoffSection       -LogoffResult $Context.LogoffResult
        New-HtmlSummarySection      -Summary $Context.Summary
        New-HtmlDisabledUsersSection -DisabledSessions $Context.DisabledSessions
        New-HtmlServerGroupsSection -ServerGroups $Context.ServerGroups
        New-HtmlOfflineHostsSection -OfflineHosts $Context.OfflineHosts
        New-HtmlErroredHostsSection -ErroredGroups $Context.ErroredGroups
        New-HtmlFooterSection       -Meta $meta
    )

    $body = ($sections | Where-Object { $_ -ne '' }) -join "`n"

    @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>$title</title>
$(Get-ReportCss)
</head>
<body>
<div class="container">
$body
</div>
</body>
</html>
"@
}
