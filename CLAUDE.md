# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Tracki — a lightweight, **zero-dependency** Toggl Track menu-bar app for macOS 13+. Pure
Foundation / AppKit / SwiftUI / Security / URLSession / async-await. No third-party packages;
keep it that way (`Package.swift` has an empty dependency list by design).

## Commands

```sh
swift build            # fast debug compile — the primary inner-loop check
make bundle            # release build → assembles & ad-hoc-signs dist/Tracki.app
make run               # bundle + launch from dist/
make install           # bundle + install to /Applications + re-sign (quits any running copy)
make clean             # rm -rf .build dist
make screenshot        # render docs/screenshot.png from the real UI (via --screenshot flag)

# Regenerate the app icon after editing scripts/make-icon.swift:
swift scripts/make-icon.swift dist/AppIcon.iconset && iconutil -c icns dist/AppIcon.iconset -o Tracki/AppIcon.icns
```

There are **no tests** and no lint config. `swift build` is the correctness gate. An Xcode
route also exists (`brew install xcodegen && xcodegen generate` via `project.yml`), but the
Makefile/SPM path is canonical and needs only Command Line Tools.

## Architecture

**Menu-bar-only app.** `TrackiApp.swift` is an `@main` `NSApplicationDelegate` with
`.accessory` activation policy (no Dock icon; `LSUIElement` in Info.plist).
`StatusBarController` owns the `NSStatusItem` (live `HH:MM:SS` while running, icon when idle)
and a transient `NSPopover` hosting the SwiftUI tree via `NSHostingController`.

**One view model, backend-agnostic.** `TimerViewModel` (`@MainActor ObservableObject`) holds
all app state and talks only to the `TogglBackend` protocol — never to a concrete client.
`RootView` switches between `TimerView` and `SettingsView` off `viewModel.screen`.

**The backend abstraction is the key design.** `TogglBackend.swift` defines the protocol +
`TogglBackendFactory`, which routes by **token prefix**:
- `toggl_sk_…` → `TogglV2Client` (Toggl 2.0 / "Focus" API, `focus.toggl.com/api`, Bearer auth,
  organization-scoped). Requires a manually-entered **Organization ID** (it cannot be discovered
  with an API key — see `docs/toggl-v2-api.md` for the full reverse-engineering notes and why).
- anything else → `ClassicTogglBackend`, a thin wrapper over `TogglAPIClient` (classic Toggl
  Track v9, `api.toggl.com/api/v9`, HTTP Basic `token:api_token`).

When adding a backend capability, change it in **three places**: the `TogglBackend` protocol,
`ClassicTogglBackend`, and `TogglV2Client`.

**Resilient sync semantics** (spread across the two backends + the view model — preserve these):
- Stop swallows **HTTP 409** (already stopped) and **404** (entry gone); `update` also swallows
  404 so a missing entry doesn't abort the stop sequence.
- **402** (Toggl 2.0 plan gate) is *never* fatal: `start`/`stop`/`currentEntry` fall back to the
  generic `/time-entries` CRUD, and `connect()` treats a 402 on projects/clients as non-fatal so
  login still succeeds with a working timer.
- **400/403** on org-scoped v2 endpoints is remapped to a "check your Organization ID" hint
  (`TogglV2Client.mapOrganizationError`) instead of failing the connection.

**Offline-first timer + deferred sync.** `TimerViewModel` can run a timer with no server round-trip
(`localRunStart`, persisted in `UserDefaults` so it survives a restart). On stop, or when any
online stop fails, the completed entry is queued to `PendingEntryStore` (JSON at
`~/Library/Application Support/Tracki/pending-entries.json`). `syncPending()` flushes the queue via
`backend.createCompleted(...)` on every successful (re)connect and on popover open; `TimerView`
shows an "Unsynced" section for anything still stuck. The running timer **always clears** so the UI
never gets stuck.

**GitHub PR title sync, two paths** (`TimerViewModel` + `Services`/`Networking`):
1. `BrowserTabReader` reads the frontmost tab of Safari/Chrome/Arc via `NSAppleScript` on popover
   open; a PR title auto-fills the description.
2. Pasting a PR URL into the description triggers `GitHubPRURLParser` + `GitHubAPIClient` to replace
   the URL with the fetched title.

## Gotchas / conventions

- **`LSUIElement` apps have no main menu**, so ⌘X/C/V/A don't route by default. `TrackiApp`
  installs an invisible Edit menu (`installEditMenu()`) so the token field is pasteable. Don't
  remove it.
- **Credential handling:** never print API tokens (or partial tokens) to logs/stdout during
  debugging — status codes and lengths only. Tokens live in the Keychain (`KeychainHelper`).
- **Dates:** both API clients use a custom `ISO8601` decoder with a fractional-seconds fallback;
  the v2 client sends RFC3339 via `ISO8601DateFormatter`. Reuse those, don't hand-roll parsing.
- The Toggl entry is created at **Start** and finalized (with description/project edits) at **Stop**
  — there is intentionally no historical editing except the offline re-sync path above.
- The menu-bar glyph is an SF Symbol *template* image; the colored `.icns` is only for
  Dock/Finder/Spotlight. Keep them separate.
