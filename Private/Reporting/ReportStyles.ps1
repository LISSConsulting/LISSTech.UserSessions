# -----------------------------------------------------------------------------
# ReportStyles.ps1 — design tokens and CSS for HTML reports.
#
# The CSS is a here-string, but it's isolated from rendering logic. When
# something visual changes (color, shadow, spacing), only this file is
# touched. The palette hashtable below mirrors the CSS custom properties,
# so if any future PowerShell code ever needs a color value, it can read
# it here rather than duplicating hex codes across files.
#
# Neobrutal design language:
#   - Thick black borders (3-4px solid)
#   - Flat saturated colors (no gradients)
#   - Heavy drop shadows (6-10px offset, 0 blur, solid black)
#   - 900-weight typography for headings
#   - Tabular-numeric monospace for data
#   - Print CSS strips shadows and cream background
# -----------------------------------------------------------------------------

# --- Design tokens ----------------------------------------------------------

$script:ReportPalette = @{
    Bg       = '#ffffff'
    Card     = '#f5f1e8'  # cream paper feel
    Ink      = '#000000'  # all borders, all shadows
    Muted    = '#6b6b6b'
    Blue     = '#2e71b8'  # primary — banner, links
    Green    = '#7fd865'
    GreenLt  = '#c7f464'
    Amber    = '#ffd43b'
    AmberLt  = '#ffe66d'
    Red      = '#ef4444'
    RedLt    = '#ffb3ba'
    Pink     = '#ff6b9d'  # "current session" accent
    Purple   = '#b794f4'
    Mint     = '#4ecdc4'
}

function Get-ReportPalette {
    <#
    .SYNOPSIS
        Returns the palette hashtable. Kept as a function (not a bare
        $script:-scoped var read by callers) so dependencies flow
        through a testable seam.
    #>
    $script:ReportPalette
}

# --- CSS block --------------------------------------------------------------

function Get-ReportCss {
    <#
    .SYNOPSIS
        Returns the <style>...</style> block for the HTML report. One
        self-contained unit, no external fonts or stylesheets, print-ready.
    #>
    @'
<style>
  :root {
    --bg:        #ffffff;
    --card:      #f5f1e8;
    --ink:       #000000;
    --muted:     #6b6b6b;
    --blue:      #2e71b8;
    --blue-lt:   #a7c8e8;
    --green:     #7fd865;
    --green-lt:  #c7f464;
    --amber:     #ffd43b;
    --amber-lt:  #ffe66d;
    --red:       #ef4444;
    --red-lt:    #ffb3ba;
    --pink:      #ff6b9d;
    --purple:    #b794f4;
    --mint:      #4ecdc4;
    --shadow:    6px 6px 0 var(--ink);
    --shadow-lg: 10px 10px 0 var(--ink);
    --border:    3px solid var(--ink);
    --border-lg: 4px solid var(--ink);
  }

  * { box-sizing: border-box; }

  html, body {
    margin: 0;
    padding: 0;
    background: var(--bg);
    color: var(--ink);
    font-family: "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif;
    font-size: 15px;
    line-height: 1.45;
    font-weight: 500;
    -webkit-font-smoothing: antialiased;
  }

  .container {
    max-width: 1080px;
    margin: 2.5rem auto;
    padding: 0 1.5rem;
  }

  .mono {
    font-family: "JetBrains Mono", "Cascadia Mono", "Consolas", ui-monospace, monospace;
    font-variant-numeric: tabular-nums;
    font-weight: 600;
  }

  /* ============================================================ BANNER */
  .banner {
    background: var(--blue);
    color: #fff;
    border: var(--border-lg);
    box-shadow: var(--shadow-lg);
    padding: 2rem 2.25rem;
    margin-bottom: 1.75rem;
    display: grid;
    grid-template-columns: 1fr auto;
    gap: 1.5rem;
    align-items: center;
  }
  .banner h1 {
    margin: 0;
    font-size: 2.25rem;
    font-weight: 900;
    letter-spacing: -0.03em;
    line-height: 1.05;
  }
  .banner .version {
    display: inline-block;
    background: var(--amber-lt);
    color: var(--ink);
    border: var(--border);
    padding: 0.15em 0.55em;
    margin-left: 0.5em;
    font-family: "JetBrains Mono", monospace;
    font-size: 0.7em;
    font-weight: 700;
    vertical-align: middle;
    box-shadow: 3px 3px 0 var(--ink);
  }
  .banner .tagline {
    margin: 0.6rem 0 0 0;
    font-size: 1rem;
    font-weight: 500;
    opacity: 0.95;
  }
  .banner .brand {
    text-align: right;
    line-height: 1;
  }
  .banner .brand-mark {
    font-size: 2.6rem;
    font-weight: 900;
    letter-spacing: -0.06em;
    background: #fff;
    color: var(--ink);
    border: var(--border);
    padding: 0.3rem 0.7rem;
    display: inline-block;
    box-shadow: 4px 4px 0 var(--ink);
  }
  .banner .brand-sub {
    margin-top: 0.4rem;
    font-size: 0.8rem;
    font-weight: 700;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    opacity: 0.9;
  }

  /* ============================================================ META STRIP */
  .meta-strip {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 0.9rem;
    margin-bottom: 1.75rem;
  }
  .meta-item {
    background: var(--card);
    border: var(--border);
    box-shadow: var(--shadow);
    padding: 0.9rem 1rem;
  }
  .meta-label {
    display: block;
    font-size: 0.7rem;
    font-weight: 800;
    letter-spacing: 0.15em;
    text-transform: uppercase;
    color: var(--muted);
    margin-bottom: 0.3rem;
  }
  .meta-value {
    font-family: "JetBrains Mono", monospace;
    font-size: 0.95rem;
    font-weight: 700;
    color: var(--ink);
    word-break: break-word;
  }

  /* ============================================================ LOGOFF */
  .logoff {
    display: grid;
    grid-template-columns: auto 1fr;
    gap: 1.5rem;
    align-items: center;
    padding: 1.5rem 2rem;
    border: var(--border-lg);
    box-shadow: var(--shadow-lg);
    margin-bottom: 1.75rem;
  }
  .logoff.success { background: var(--green-lt); }
  .logoff.mixed   { background: var(--amber-lt); }
  .logoff.failure { background: var(--red-lt); }
  .logoff-icon {
    font-size: 3.5rem;
    line-height: 1;
    font-weight: 900;
    width: 5rem;
    height: 5rem;
    display: flex;
    align-items: center;
    justify-content: center;
    background: #fff;
    border: var(--border);
    box-shadow: 4px 4px 0 var(--ink);
  }
  .logoff-count {
    font-size: 2.2rem;
    font-weight: 900;
    letter-spacing: -0.02em;
    line-height: 1;
  }
  .logoff-sub {
    margin-top: 0.4rem;
    font-size: 1rem;
    font-weight: 600;
  }

  /* ============================================================ SECTION TITLE */
  .section-title {
    font-size: 1.3rem;
    font-weight: 900;
    letter-spacing: 0.02em;
    text-transform: uppercase;
    margin: 2.25rem 0 1rem 0;
    padding-bottom: 0.4rem;
    border-bottom: var(--border-lg);
    display: flex;
    align-items: center;
    gap: 0.6rem;
  }
  .section-title .badge {
    display: inline-block;
    background: var(--ink);
    color: var(--amber-lt);
    font-family: "JetBrains Mono", monospace;
    font-size: 0.75rem;
    font-weight: 700;
    padding: 0.1em 0.55em;
  }

  /* ============================================================ SUMMARY */
  .summary-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
    gap: 0.9rem;
  }
  .stat-card {
    background: var(--card);
    border: var(--border);
    box-shadow: var(--shadow);
    padding: 1rem 1.1rem;
    position: relative;
    overflow: hidden;
  }
  .stat-card .stat-label {
    font-size: 0.7rem;
    font-weight: 800;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    color: var(--muted);
    margin-bottom: 0.3rem;
  }
  .stat-card .stat-value {
    font-family: "JetBrains Mono", monospace;
    font-size: 2.25rem;
    font-weight: 900;
    letter-spacing: -0.03em;
    line-height: 1;
    color: var(--ink);
  }
  .stat-card.active    { background: var(--green-lt); }
  .stat-card.disc      { background: var(--amber-lt); }
  .stat-card.disabled  { background: var(--red-lt); }
  .stat-card.offline   { background: #e0e0e0; }
  .stat-card.errored   { background: var(--red-lt); }

  /* ============================================================ ALERT BLOCK */
  .alert {
    background: var(--amber-lt);
    border: var(--border-lg);
    box-shadow: var(--shadow);
    padding: 1.25rem 1.5rem;
    margin-bottom: 1.25rem;
  }
  .alert.danger { background: var(--red-lt); }
  .alert h3 {
    margin: 0 0 0.4rem 0;
    font-size: 1.1rem;
    font-weight: 900;
    letter-spacing: 0.02em;
    text-transform: uppercase;
  }
  .alert p {
    margin: 0;
    font-size: 0.95rem;
    font-weight: 500;
  }

  /* ============================================================ SERVER CARD */
  .server-card {
    background: var(--card);
    border: var(--border);
    box-shadow: var(--shadow);
    margin-bottom: 1.5rem;
    overflow: hidden;
  }
  .server-header {
    background: var(--ink);
    color: #fff;
    padding: 0.85rem 1.25rem;
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 1rem;
    flex-wrap: wrap;
  }
  .server-name {
    font-family: "JetBrains Mono", monospace;
    font-size: 1.05rem;
    font-weight: 700;
    letter-spacing: 0.01em;
  }
  .server-chips {
    display: flex;
    gap: 0.4rem;
    flex-wrap: wrap;
  }
  .chip {
    display: inline-flex;
    align-items: center;
    gap: 0.35em;
    padding: 0.2em 0.7em;
    font-family: "JetBrains Mono", monospace;
    font-size: 0.8rem;
    font-weight: 700;
    border: 2px solid #fff;
    color: #fff;
  }
  .chip.active { background: var(--green); color: var(--ink); border-color: var(--ink); }
  .chip.disc   { background: var(--amber); color: var(--ink); border-color: var(--ink); }

  /* ============================================================ SESSION TABLE */
  table.sessions {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.9rem;
  }
  table.sessions th {
    background: var(--bg);
    padding: 0.6rem 0.9rem;
    text-align: left;
    font-size: 0.7rem;
    font-weight: 800;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    color: var(--muted);
    border-bottom: var(--border);
  }
  table.sessions td {
    padding: 0.6rem 0.9rem;
    border-bottom: 1px solid #e5e0d4;
    vertical-align: middle;
  }
  table.sessions tbody tr:last-child td { border-bottom: none; }
  /* Right-anchor the rightmost column so the timestamp sits flush against
     the row's right edge. Without this, table-layout: auto distributes the
     row's free width across the last cell, leaving a visible empty stripe
     on the right side of every row when the report pastes into a wider
     editor (HaloPSA, Outlook). */
  table.sessions th:last-child,
  table.sessions td:last-child { text-align: right; }

  .state-pill {
    display: inline-block;
    padding: 0.12em 0.65em;
    font-family: "JetBrains Mono", monospace;
    font-size: 0.78rem;
    font-weight: 700;
    border: 2px solid var(--ink);
    text-transform: uppercase;
    letter-spacing: 0.03em;
  }
  .state-pill.active { background: var(--green-lt); }
  .state-pill.disc   { background: var(--amber-lt); }
  .state-pill.other  { background: #e0e0e0; }

  .mark {
    display: inline-block;
    width: 1.25em;
    text-align: center;
    font-weight: 900;
  }
  .mark.active   { color: var(--green); }
  .mark.disc     { color: #c48a00; }
  .mark.current  { color: var(--pink); }

  .user-cell { font-family: "JetBrains Mono", monospace; font-weight: 700; }
  .user-cell.disabled {
    color: var(--red);
    text-decoration: line-through;
  }
  .disabled-badge {
    display: inline-block;
    margin-left: 0.4em;
    background: var(--red);
    color: #fff;
    font-family: "JetBrains Mono", monospace;
    font-size: 0.7rem;
    font-weight: 700;
    padding: 0.08em 0.45em;
    border: 2px solid var(--ink);
    letter-spacing: 0.05em;
  }

  td.idle.hot { color: var(--red); font-weight: 800; }

  /* ============================================================ PILLS */
  .pill-list {
    display: flex;
    flex-wrap: wrap;
    gap: 0.4rem;
  }
  .pill {
    display: inline-block;
    background: var(--card);
    border: 2px solid var(--ink);
    padding: 0.3em 0.7em;
    font-family: "JetBrains Mono", monospace;
    font-size: 0.82rem;
    font-weight: 600;
    box-shadow: 2px 2px 0 var(--ink);
  }

  /* ============================================================ ERROR GROUPS */
  .error-group {
    background: var(--card);
    border: var(--border);
    box-shadow: var(--shadow);
    margin-bottom: 1rem;
    overflow: hidden;
  }
  .error-group-header {
    background: var(--red);
    color: #fff;
    padding: 0.75rem 1.1rem;
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 1rem;
  }
  .error-group-header .msg {
    font-weight: 700;
    letter-spacing: 0.01em;
  }
  .error-group-header .count {
    font-family: "JetBrains Mono", monospace;
    font-weight: 700;
    background: var(--ink);
    padding: 0.15em 0.6em;
    border: 2px solid #fff;
  }
  .error-group-body { padding: 0.9rem 1.1rem; }

  /* ============================================================ FOOTER */
  .footer {
    margin-top: 3rem;
    padding-top: 1.5rem;
    border-top: var(--border);
    font-size: 0.85rem;
    color: var(--muted);
    display: flex;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 1rem;
  }
  .footer code {
    background: var(--ink);
    color: var(--green-lt);
    padding: 0.1em 0.4em;
    font-family: "JetBrains Mono", monospace;
    font-size: 0.85rem;
    font-weight: 700;
  }
  details summary {
    cursor: pointer;
    font-weight: 700;
    color: var(--ink);
  }
  details[open] summary { margin-bottom: 0.5rem; }

  /* ============================================================ PRINT */
  @media print {
    html, body { background: #fff; }
    .container { max-width: none; margin: 0; padding: 1cm; }
    .banner, .server-header, .server-card, .stat-card, .meta-item,
    .logoff, .alert, .error-group {
      box-shadow: none !important;
    }
    .section-title { page-break-after: avoid; }
    .server-card, .error-group, .alert { page-break-inside: avoid; }
    table.sessions { page-break-inside: auto; }
    table.sessions tr { page-break-inside: avoid; }
  }
</style>
'@
}

# --- Copy-to-clipboard widget ----------------------------------------------

function Get-ReportCopyWidget {
    <#
    .SYNOPSIS
        Returns a self-contained "Copy for Halo / Outlook" button + script.

        Why: rich-text editors (HaloPSA, in particular) strip <style> tags
        on paste, even from inside the CF_HTML fragment. The CF_HTML write
        we do from PowerShell therefore pastes unstyled. The browser, when
        you Ctrl+A → Ctrl+C, runs its native copy path which serializes
        the selection with computed styles inlined per element — and THAT
        markup pastes beautifully.

        Triggering the same path from a button is reliable: select the
        report content into a Range and call document.execCommand('copy').
        Browser security requires a user gesture, so auto-copy on load is
        not an option; a click is the gesture.

        Hidden in print media so it doesn't appear in PDF exports.
    #>
    @'
<button type="button" id="liss-copy-btn"
        style="position:fixed;top:1rem;left:50%;transform:translateX(-50%);z-index:9999;
               padding:0.7em 1.4em;font-family:'Inter',-apple-system,sans-serif;
               font-size:0.9rem;font-weight:800;letter-spacing:0.08em;
               text-transform:uppercase;background:#7fd865;color:#000;
               border:3px solid #000;box-shadow:4px 4px 0 #000;cursor:pointer;
               transition:background 80ms ease;">
  Copy for Halo / Outlook
</button>
<style media="screen">
  /* Hover/active need a single transform property so they don't fight the
     translateX(-50%) used to center the button. */
  #liss-copy-btn:hover  { transform: translate(calc(-50% - 1px), -1px); box-shadow: 5px 5px 0 #000; }
  #liss-copy-btn:active { transform: translate(calc(-50% + 2px),  2px); box-shadow: 2px 2px 0 #000; }
</style>
<style media="print">
  #liss-copy-btn { display: none !important; }
</style>
<script>
  (function () {
    var btn = document.getElementById('liss-copy-btn');
    if (!btn) return;
    var original = btn.textContent;
    btn.addEventListener('click', function () {
      var target = document.querySelector('.container') || document.body;
      // setStartBefore / setEndAfter on the first/last ELEMENT children
      // skips the leading/trailing whitespace text nodes that sit between
      // the container's tags and its children — those produce phantom blank
      // lines in the paste otherwise.
      if (!target.firstElementChild || !target.lastElementChild) return;
      var sel = window.getSelection();
      var range = document.createRange();
      btn.style.visibility = 'hidden';   // not selectable while we copy
      range.setStartBefore(target.firstElementChild);
      range.setEndAfter(target.lastElementChild);
      sel.removeAllRanges();
      sel.addRange(range);
      var ok = false;
      try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
      sel.removeAllRanges();
      btn.style.visibility = 'visible';
      btn.textContent = ok ? 'Copied!' : 'Copy failed';
      btn.style.background = ok ? '#c7f464' : '#ffb3ba';
      setTimeout(function () {
        btn.textContent = original;
        btn.style.background = '#7fd865';
      }, 1800);
    });
  })();
</script>
'@
}

# --- HTML escape helper -----------------------------------------------------

function ConvertTo-HtmlSafe {
    <#
    .SYNOPSIS
        Minimal HTML escape for interpolating user/server names safely.
        Covers the characters that matter in practice; we never
        interpolate anything where full XSS-style escape is needed
        (this is an offline report, not a web page).
    #>
    param([string]$Text)
    if (-not $Text) { return '' }
    $Text = $Text -replace '&',  '&amp;'
    $Text = $Text -replace '<',  '&lt;'
    $Text = $Text -replace '>',  '&gt;'
    $Text = $Text -replace '"',  '&quot;'
    $Text = $Text -replace "'",  '&#39;'
    return $Text
}
