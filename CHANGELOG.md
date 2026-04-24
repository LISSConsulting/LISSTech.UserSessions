# Changelog

All notable changes to LISSTech.UserSessions are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [CalVer](https://calver.org/) with scheme `YY.DOY.patch`.

---

## [26.113.2] — 2026-04-23

### Changed

- **Reporting subsystem refactored into `Private/Reporting/`** — the
  1,100-line `Format-Report.ps1` monolith split into six files along
  SRP / SOLID lines. One concept per file.

  | File | Responsibility |
  |---|---|
  | `ReportModel.ps1` | View-model shaping, ubiquitous language, session formatters |
  | `ReportStyles.ps1` | Design tokens (palette) and CSS — one source of visual truth |
  | `ReportHtmlSections.ps1` | One pure function per HTML section (Banner, Summary, DisabledUsers, ServerGroups, OfflineHosts, ErroredHosts, Footer) |
  | `ReportHtml.ps1` | HTML composition — reads like a document outline |
  | `ReportMarkdown.ps1` | Markdown composition, same `ReportContext` input |
  | `ReportDispatch.ps1` | Side effects (file write, clipboard, browser launch) |

- **New seam: `New-ReportContext`**. Renderers no longer consume
  `$ScanResult` directly — they consume a presentation-layer ViewModel.
  Tests can construct synthetic contexts without faking the scan
  pipeline.

- **Extracted pure decision functions**:
  - `Resolve-ReportClipboardDecision`
  - `Resolve-ReportFilePath`

  These were embedded in dispatch and not unit-testable. Now they are.

- **Invoke-ReportDispatch now returns a result object**
  (`@{ Format, FilePath, Clipboard, BrowserOpened }`) instead of
  returning nothing. Callers can use it for logging / confirmation.

### Added

- **BDD Pester suite** in `tests/LISSTech.UserSessions.Tests/ReportRendering.Tests.ps1`.
  Given/When/Then structure covering:
  - ReportContext construction behavior
  - HTML rendering output (structure, CSS presence, section inclusion)
  - Markdown rendering output
  - Clipboard decision logic across all argument combinations
  - File-path resolution logic

  Tests run without touching disk or clipboard — all side effects are
  at the module edge.

### Unchanged

- `Show-UserSession -Report` user-facing behavior is identical. The
  refactor is internal plumbing.

---

## [26.113.1] — 2026-04-23

### Added

- **`-Report html` now clipboards as rendered HTML.** Uses the Windows
  CF_HTML clipboard format (via `System.Windows.Forms.Clipboard.SetText`
  with `TextDataFormat.Html`) so pasting into HaloPSA, Outlook, Word,
  Gmail, or any rich-text editor yields the formatted report — tables,
  colors, borders, and all — not raw HTML source.
- **Browser preview is still the default.** The temp file is written
  and opened exactly as before; the clipboard write is additive.
- New private helper `Set-ClipboardHtml` in `Format-Report.ps1` with
  STA-thread dispatch so it works on both Windows PowerShell 5.1
  (STA by default) and PowerShell 7 (MTA by default).

### Changed

- Behavior matrix:
  - `-Report html`: rendered clipboard + browser preview *(default)*
  - `-Report html -ReportPath x.html`: file only, silent attachment mode
    (no browser, no clipboard) unless `-Clipboard` is also given
  - `-Report html -Clipboard:$false`: browser preview only, clipboard
    untouched
- Updated `Show-UserSession` help text and README behavior matrix
  accordingly.

---

## [26.113.0] — 2026-04-23

### Changed

- **Module renamed** from `LISSTech.UserSession` to `LISSTech.UserSessions`
  (plural). The module name refers to the domain / collection; cmdlet names
  remain singular per PowerShell's approved-verb + singular-noun convention.
- **Emitted session object type** renamed `LISSTech.UserSession` to
  `LISSTech.UserSessions.Session` — matches the module identity and makes
  the type tag more precise (this object represents a single session).
- **Versioning scheme** switched to CalVer (`YY.DOY.patch`) matching the
  LISSTech.Billboard convention. Prior SemVer history preserved below.

### Added

- Full GitHub repository scaffolding mirroring `LISSTech.Billboard`:
  - `README.md` with badges, navigation, Mermaid architecture + flow +
    release pipeline diagrams, quick start, API reference, Reports doc,
    maintenance workflow section, build instructions, project structure tree,
    and safety table
  - `LICENSE` — Apache 2.0
  - `.gitignore`, `.env.example`
  - `justfile` with recipes: `test`, `lint`, `bom`, `bump`, `package`,
    `sign`, `release`, `publish`, `install`, `clean`
  - `CLAUDE.md` — AI pair-programming conventions and gotchas
  - `docs/` with brand asset placeholder
  - `scripts/` with `Apply-Bom.ps1` (enforce UTF-8 BOM) and
    `Bump-Version.ps1` (CalVer bumper)
  - `tests/LISSTech.UserSessions.Tests/` with Pester 5.x skeleton
    covering manifest validity, BOM compliance, parser-hazard sweeps,
    and parameter contract tests

### Unchanged

- All three public cmdlets — `Find-UserSession`, `Show-UserSession`,
  `Stop-UserSession` — keep their names.
- Parameter names, aliases, and filter semantics are identical.
- All the feature work from v1.5.0: dashboard rendering, async parallel
  logoff, reports (markdown + neobrutal HTML), disabled-user detection.

---

## Prior history — LISSTech.UserSession (singular)

The following releases shipped under the prior module name
`LISSTech.UserSession`. They are carried forward verbatim for continuity.

### [1.5.0] — 2026-04-23 — Ticket-ready reports

- `-Report markdown|html` on `Show-UserSession`. Markdown → clipboard;
  HTML → temp file + browser. Neobrutal HTML design. `-ReportPath` for
  explicit file output; `-Clipboard` switch. `Start-AsyncLogoff` returns
  a result summary. Canonical maintenance one-liner:
  `Show-UserSession -LogOff -Confirm:$false -Report markdown`

### [1.4.3] — Column alignment fix

Header row's STATE/SESSION/ID/IDLE/LOGON now line up with data rows.
Column widths extracted to `$script:Col`.

### [1.4.2] — LOGOFF panel border fix + tagline swap

Bottom border renders immediately. Tagline: "Enumerate, audit, and log
off Terminal Services sessions across AD."

### [1.4.1] — Banner rewrite

Replaced "SESSION HUNTER" flavor banner with module name, dynamic
version, LISS brand, tagline, runtime context.

### [1.4.0] — Parameter naming consistency

`Stop-UserSession` primary parameter renamed `-Server` → `-ComputerName`;
alias preserved.

### [1.3.2] — Header separator color

`├───┤` separator matches main border color.

### [1.3.1] — Glyphs, colors, and overflow

`[Console]::OutputEncoding = UTF-8` at module import. Bright-white bold
headers. Disabled-user row truncation. `switch ($true)` → if/elseif.

### [1.3.0] — Readability and portability

Stripped client-specific defaults. ID column 6 → 9. Panel 88 → 96. Top
border math fixed. Humanized WTS error messages. Error grouping.

### [1.2.2] — Two parser bugs fixed

`$MinIdleDays:` PSDrive parsing; scriptblock switch conditions now
paren-wrapped per convention.

### [1.2.1] — Bugfix

Fixed parser error in `Format-Fixed` (`return switch` with scriptblock
conditions).

### [1.2.0] — Offboarding visibility

`IsUserDisabled` property. `-OnlyDisabled` switch. Red username + `⚠
DISABLED` badge on disabled-user rows.

### [1.1.0] — Dependency diet

Removed `ActiveDirectory` RSAT dependency via DirectorySearcher.
Default computer discovery returns all enabled computers.
`-ServerLdapFilter` → `-ComputerLdapFilter` (alias preserved).

### [1.0.0] — Initial release

`Find-UserSession`, `Show-UserSession`, `Stop-UserSession`.
WTSEnumerateSessions P/Invoke. Parallel scanning via RunspacePool.
Docker-style async logoff renderer. ShouldProcess/WhatIf/Confirm.
