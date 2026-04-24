# CLAUDE.md — AI pair-programming instructions for LISSTech.UserSessions

This document captures conventions, patterns, and gotchas Claude (or any
other AI pair-programming agent) should internalize before editing this
module. Human maintainers can skim it too.

---

## The product in one sentence

A PowerShell module for MSPs to enumerate, audit, and log off Windows
Terminal Services sessions across an Active Directory domain — built
around WTS Win32 API P/Invoke, runspace-pool parallelism, a rich ANSI
dashboard, and a ticket-ready HTML report.

Primary use case: **scheduled maintenance-window bulk logoffs** (e.g.,
"please log everyone off the RDS farm tonight at 10pm"). Secondary use cases:
incident response, offboarding sweeps, stuck-session cleanup.

---

## Non-negotiables

These rules are load-bearing. Break them and the module stops working
on the target environment (Windows Server 2016+, PowerShell 5.1).

### UTF-8 BOM on every source file

Every `.ps1`, `.psm1`, `.psd1`, and `.md` **must** start with the BOM
bytes `EF BB BF`. Windows PowerShell 5.1 defaults to the OEM codepage
(437 / 1252) for unmarked files, which mangles the box-drawing characters
(`│ ─ ┌ ┘`), status glyphs (`● ○ ★ ◆`), and warning signs (`⚠`) this
module relies on.

Always run `just bom` (or `scripts/Apply-Bom.ps1`) as the last step
before packaging. `just lint` verifies BOMs are present and fails loudly
if any are missing.

### `[Console]::OutputEncoding = UTF-8` at module import

VT processing and console output encoding are **independent** concerns.
VT (`ENABLE_VIRTUAL_TERMINAL_PROCESSING`) controls escape-code interpretation.
`[Console]::OutputEncoding` controls which bytes get written to the console
buffer. Both must be set; skipping the second renders Unicode glyphs as `?`.
This is set in `Private/Format-Display.ps1` at module import.

### No backtick line continuations

Use splat hashtables (`$params = @{ ... }; cmd @params`) or `-f` with an
`$args` array. Backticks are fragile and visually invisible; grep for
them in `just lint`.

### `switch` idioms

- **`switch` case labels that are scriptblocks must be wrapped in parens**:
  `({ $_ -lt 1000 }) { ... }`, not `{ $_ -lt 1000 } { ... }`. Bare
  scriptblocks as case labels are valid PowerShell but visually collide
  with statement-body braces and have tripped the parser before.
- Never use `return switch` — PowerShell's parser rejects `return` + a
  switch with scriptblock conditions. Use plain `if`/`elseif`/`else`.
- Prefer `if`/`elseif` over `switch ($true) { $var1 { ... } $var2 { ... } }`
  — the latter is clever but brittle to `$null` property access.

### Variable references in double-quoted strings

Never write `"$var:something"` — PowerShell parses `$var:` as a PSDrive
reference. Use `"${var}:something"` to delimit the variable name.

### Cmdlet naming

Module name is **plural** (`LISSTech.UserSessions`) because it's a
collection/namespace. Cmdlet names are **singular**
(`Find-UserSession`, `Show-UserSession`, `Stop-UserSession`) per
PowerShell's approved-verb + singular-noun convention. Do not pluralize
cmdlets.

### Parameter naming

`-ComputerName` is the canonical parameter on all three public cmdlets.
`-Server` and `-Name` are aliases for back-compat and pipeline-binding
flexibility. The emitted `PSObject` schema uses `Server` as the
property name to match `LISSTech.UserSessions.Session` type conventions.
Parameter names and property names are deliberately separate: humans
type `-ComputerName`, the data model says `Server`.

---

## Architecture

```
Invoke-UserSessionScan          ← orchestrator (private)
  ├── Search-Directory          ← DirectorySearcher (AD lookups)
  └── Invoke-RunspaceBatch      ← RunspacePool fan-out
        └── ScanScript          ← WTS P/Invoke per target
              └── emits LISSTech.UserSessions.Session objects
                    ├── Format-Display       ← ANSI dashboard
                    │
                    ├── Reporting/           ← report subsystem
                    │   ├── ReportModel      ← view-model shaping
                    │   ├── ReportStyles     ← palette + CSS
                    │   ├── ReportHtmlSections ← section renderers (one per)
                    │   ├── ReportHtml       ← composer
                    │   └── ReportDispatch   ← file/clipboard/browser
                    │
                    └── Start-AsyncLogoff    ← parallel logoff
```

### Reporting subsystem design

The reporting pipeline is structured to keep side effects at the edge:

```
[raw scan+logoff+scope] → New-ReportContext → [presentation ViewModel]
  → Format-ReportHtml → [string]
  → Invoke-ReportDispatch → [file / clipboard / browser]
```

Key seams:

- **`New-ReportContext`** is the domain→presentation boundary. Tests
  build synthetic contexts directly; they never have to fake a scan.
- **Section renderers** in `ReportHtmlSections.ps1` are pure functions.
  Each takes only its slice of the context, returns an HTML string,
  knows nothing about other sections. Adding a new section = new
  function + one line in the composer. Nothing existing gets edited
  (OCP in its useful form).
- **`Resolve-ReportClipboardDecision`** and **`Resolve-ReportFilePath`**
  are pure decision functions extracted from dispatch. They can be
  unit-tested without any IO. This was how the clipboard behavior bug
  used to bite us — now the logic is isolated and testable.
- **`Invoke-ReportDispatch`** is the only thing in Reporting/ that
  touches the filesystem or clipboard. Everything else is pure.

### Why the style lives in PowerShell rather than a template file

Considered extracting the CSS and section templates to
`docs/templates/*.html`. Rejected for this module because:

- Single-file distribution (`Install-Module`) is a real feature —
  no runtime file discovery failure modes.
- There's one human (Marcin) iterating; separation-of-concerns pays
  most when different people own different layers.
- PowerShell's string interpolation is already a templating engine.
  Adding Jinja-style placeholder syntax would reinvent it badly.
- CSS is write-once-and-stable; the parts that change during iteration
  are DOM structure and which sections appear, which are still in
  PowerShell regardless.

If a second consumer of the LISS brand report style ever appears
(Billboard, DrainCtl, etc.), extract to a shared `LISSTech.ReportKit`
module at that point — not before.

The three public cmdlets are thin wrappers around this orchestrator:

- `Find-UserSession` — scan, return objects, exit
- `Show-UserSession` — scan, render dashboard, optionally logoff + report
- `Stop-UserSession` — single-session logoff via `WTSLogoffSession` P/Invoke

### Why no `Get-ADUser`/`Get-ADComputer`

The `ActiveDirectory` RSAT module is not always installed on target
machines (particularly on DCs where it would make sense, but is
sometimes also absent on fresh Server Core installs). Using
`System.DirectoryServices.DirectorySearcher` from the base .NET
install makes this module run out-of-box on any domain-joined Windows
host. `Search-Directory.ps1` is the thin wrapper.

### Why RunspacePool, not `ForEach-Object -Parallel`

`ForEach-Object -Parallel` requires PowerShell 7. This module targets
Windows PowerShell 5.1 (the default on Server 2016/2019/2022 and
Windows 10/11). RunspacePool is the PS 5.1-compatible equivalent and
gives us explicit throttle control.

### Why WTS P/Invoke, not `quser.exe`

`quser.exe` output is locale-dependent, has inconsistent formatting,
and doesn't reliably expose session IDs above 99. The WTS Win32 API
returns real integers and enum values with no parsing fragility.

---

## The emitted session object

`LISSTech.UserSessions.Session` is the core data model. It's a PSCustomObject
with a type tag, and every public cmdlet either produces or consumes it:

| Property | Type | Notes |
|---|---|---|
| `Server` | `string` | Computer name the session is on |
| `SessionId` | `int` | WTS session ID |
| `Username` | `string` | SAM account name |
| `Domain` | `string` | NetBIOS domain |
| `WinStation` | `string` | `Console`, `RDP-Tcp#N`, etc. |
| `State` | `LISSTech.Wts.WtsConnectState` | enum: Active, Disconnected, Idle, ... |
| `LogonTime` | `DateTime` | Original logon timestamp |
| `LastInputTime` | `DateTime` | For idle calculation |
| `IdleTime` | `TimeSpan` | Computed from LastInputTime |
| `IsCurrent` | `bool` | `$true` for the caller's own session — **always skipped by logoff** |
| `IsUserDisabled` | `bool` | From `userAccountControl & 0x2` on the AD user |

`IsCurrent` is the safety rail. `Show-UserSession -LogOff` and
`Stop-UserSession` skip any session where this is `$true`, preventing
self-logoff. Never remove this guard.

---

## Working with reports

`Show-UserSession -Report` generates a ticket-ready HTML artifact.
HTML is the only format — markdown was dropped because every paste
target we care about (HaloPSA, Outlook, Word) takes CF_HTML and
renders it, so the markdown source variant was always strictly
worse than the rendered version on the clipboard.

### Behavior matrix

| Args | Output |
|---|---|
| `-Report` | Temp file + browser preview + CF_HTML clipboard |
| `-Report -ReportPath P` | File at P, no browser, no clipboard |
| `-Report -ReportPath P -Clipboard` | File + CF_HTML clipboard |
| `-Report -Clipboard:$false` | Temp file + browser only |

`-ReportPath` and `-Clipboard` both imply `-Report` if the switch
itself is omitted, since neither makes sense without it.

### Auto-open rule

HTML auto-opens in the default browser **only when no explicit
`-ReportPath` is given**. If the user specified a path, assume they're
attaching it to a ticket and don't want the browser popping up.

### Clipboard format

The clipboard write uses CF_HTML (multi-format `DataObject` with both
`DataFormats.Html` and `DataFormats.UnicodeText`). The CF_HTML payload
is built by hand in `ConvertTo-CfHtml` — the fragment markers MUST be
inside `<body>`, not wrapping the `<html>` shell, or paste targets
silently fall back to plain-text. `Set-ClipboardHtml` dispatches to a
dedicated STA thread on PS7 (which is MTA by default) via the
`ClipboardBridge` C# helper.

### Neobrutal design philosophy

The HTML uses thick black borders (3-4px), flat saturated colors (no
gradients), heavy drop shadows (`6px 6px 0 #000`), 900-weight
typography, and tabular-numeric data. Print CSS strips shadows and
the cream background for clean PDF export.

This is a deliberate aesthetic choice — the report should not look
like a terminal screenshot, it should look like a *report*. Terminal
authenticity lives in the dashboard renderer (`Format-Display.ps1`),
which is a separate rendering path.

---

## When adding a new cmdlet

1. File goes in `Public/<Verb>-UserSession.ps1` (singular noun).
2. Add to `$loadOrder` in `LISSTech.UserSessions.psm1`.
3. Add to `FunctionsToExport` and `FileList` in the manifest.
4. If it operates on computers, use `-ComputerName` with aliases `Server, Name`.
5. If it has side effects, use `[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]`.
6. If it can target `IsCurrent` sessions, **filter them out before acting**.
7. Add Pester tests under `tests/LISSTech.UserSessions.Tests/`.
8. Update README's "PowerShell API" section.
9. Run `just lint` before committing.

## When modifying the dashboard

`Format-Display.ps1` has column widths stored in `$script:Col`. The
header row's lead is 2 chars (`'  '`) vs. the data row's lead of 3
chars (`' ' + mark + ' '`). The header's USER column compensates with
`Username + UserGap + (RowLead - HeadLead)` — do not hardcode widths
in either place. When adding a column, update `$script:Col` and both
the header and row builders.

## Release procedure

```
just lint         # BOM check + PSScriptAnalyzer
just test         # Pester suite
just bump         # CalVer (YY.DOY.patch)
just package      # dist/LISSTech.UserSessions-YY.DOY.patch.zip
just sign         # if CODE_SIGNING_CERTIFICATE_THUMBPRINT set
just publish      # if PSGALLERY_API_KEY set
```

CalVer format: `YY.DOY.patch` — e.g., `26.113.0` for 2026 day 113
release 0. Bump patch on bugfixes within the same day; new day
resets to 0.

---

## Known traps

- **Windows Terminal vs. conhost.** Both work, but conhost on Server
  2016 requires explicit `SetConsoleMode` with `ENABLE_VIRTUAL_TERMINAL_PROCESSING`.
  Done at module import; don't remove the kernel32 P/Invoke in `Format-Display.ps1`.
- **Console encoding resets.** If another cmdlet or module resets
  `[Console]::OutputEncoding` after our module import, glyphs will
  break. Consider setting it at the top of `Show-UserSession` too if
  this becomes an issue in practice.
- **DirectorySearcher paging.** Set `PageSize = 1000` — without it,
  domains with 1000+ users or computers silently truncate results.
- **`Win32Exception` messages are localized.** When a target host is
  unreachable via WTS, the raw message is in the OS language. We map
  known codes (5, 53, 203, 1722, 1726, 1727) to English strings.
  When adding error-code translations, update the switch in
  `Workers.ps1` (ScanScript), not the callers.
