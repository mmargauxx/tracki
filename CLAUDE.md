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

# Prepare new flyby artwork (keys out the white background, crops to content):
swift scripts/make-flyby-asset.swift <source.png> Tracki/Resources/flyby.png
```

There are **no tests** and no lint config. `swift build` is the correctness gate. An Xcode
route also exists (`brew install xcodegen && xcodegen generate` via `project.yml`), but the
Makefile/SPM path is canonical and needs only Command Line Tools.

`make screenshot` is also the fastest way to **eyeball a UI change** — `ScreenshotRenderer`
builds a `TimerViewModel` with sample data and renders the real `TimerView` offscreen, so you
never need a Toggl token or a running menu-bar app to see a view edit.

`--flyby` flies one reminder across the screen, reports whether artwork loaded, and exits —
the way to iterate on the flyby without waiting out a real reminder interval. Run it on the
**bundled** app (`make bundle && dist/Tracki.app/Contents/MacOS/Tracki --flyby`); a bare
`.build/debug/Tracki` has no `Contents/Resources`, so it always reports the text fallback
unless artwork is at the Application Support override path below.

Adding a **non-Swift file** under `Tracki/` breaks `swift build` (SPM errors on unhandled
resources) — add it to `exclude:` in `Package.swift` (currently `Info.plist`, `AppIcon.icns`,
`Resources`). App assets go in `Tracki/Resources/`, which the Makefile's `bundle` rule copies
into `Contents/Resources/`; there is deliberately **no SPM resource bundle**, so look them up
via `Bundle.main`, not `Bundle.module`.

## Releasing

Releases are **manual** — there's no CI. Distribution is a GitHub release plus a Homebrew cask
that lives in a **separate repo**, `mmargauxx/homebrew-tap` (`Casks/tracki.rb`).

```sh
# 1. Bump BOTH keys in Tracki/Info.plist: CFBundleShortVersionString (1.1.0) and
#    CFBundleVersion (2). Commit and push to main.
# 2. Build and zip. Use ditto, not `zip` — it preserves the code signature.
make bundle && ditto -c -k --keepParent dist/Tracki.app dist/Tracki.zip
# 3. Cut the release.
gh release create v1.1.0 dist/Tracki.zip -R mmargauxx/tracki --title "Tracki 1.1.0" --notes "..."
# 4. Get the checksum from the DOWNLOADED asset, not the local zip.
curl -sL -o /tmp/t.zip https://github.com/mmargauxx/tracki/releases/download/v1.1.0/Tracki.zip
shasum -a 256 /tmp/t.zip
# 5. In mmargauxx/homebrew-tap, update `version` and `sha256` in Casks/tracki.rb, then push.
# 6. Verify without installing — this downloads and validates the checksum:
brew update && brew fetch --cask mmargauxx/tap/tracki
```

Gotchas, each of which has bitten:
- **Verify the zip round-trips** before releasing: `ditto -x -k` it to a temp dir and run
  `codesign --verify --deep --strict` on the result. A signature broken by zipping is invisible
  until a user hits Gatekeeper.
- **`make install` goes behind Homebrew's back.** It overwrites `/Applications/Tracki.app`
  while brew still records the old version. `brew upgrade --cask tracki` reconciles it.
- **Upgrading doesn't stop the running app.** Brew deletes the old bundle out from under the
  live process, which keeps running the old code — quit and relaunch, or you're testing the
  previous version.
- **Brew quarantines cask installs**, and Tracki is only ad-hoc signed, so a normal upgrade
  trips Gatekeeper. Use `brew upgrade --cask --no-quarantine tracki`, or clear it after the
  fact with `xattr -d -r com.apple.quarantine /Applications/Tracki.app`.
- The cask's `zap trash:` covers `~/Library/Application Support/Tracki`, which holds both
  `pending-entries.json` and the user's custom `flyby.png`. Anything new stored elsewhere
  needs adding there.

## Architecture

**Menu-bar-only app.** `TrackiApp.swift` is an `@main` `NSApplicationDelegate` with
`.accessory` activation policy (no Dock icon; `LSUIElement` in Info.plist).
`StatusBarController` owns the `NSStatusItem` (live `HH:MM:SS` while running, icon when idle)
and a transient `NSPopover` hosting the SwiftUI tree via `NSHostingController`.

**One view model, backend-agnostic.** `TimerViewModel` (`@MainActor ObservableObject`) holds
all app state and talks only to the `TogglBackend` protocol — never to a concrete client.
`RootView` switches between `TimerView` and `SettingsView` off `viewModel.screen`.
The SwiftUI tree observes it via `@Published`, but the **menu-bar title is not bound** — it
updates only through the `onStatusChange: ((String?) -> Void)?` callback that
`StatusBarController` installs, fired from `tick()` and `clearRunningState()`. Anything that
should appear in the status item has to be routed through that closure.

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
  (`TogglV2Client.mapOrganizationError`) instead of failing the connection. For this to work
  `requestOptional` collapses **only 401** into `.unauthorized` and lets 403 stay an
  `.http(403, body)` — don't "tidy" it back to `case 401, 403`, or a wrong-org error reverts
  to reading "Invalid API token". `connect()` is the exception: it isn't org-scoped, so it
  remaps its own 403 to `.unauthorized`. Every org-scoped call routes through the mapper.
  (The classic client keeps the `401, 403` collapse — v9 has no org concept.)

**Error taxonomy.** `TogglAPIError` (declared in `TogglAPIClient.swift`, used by *both*
backends) is the single error type crossing the protocol boundary. `.configuration(String)`
is the "actionable user hint" case — its message is rendered verbatim in the UI, so write it
for the user, not the log. The view model pattern-matches on `.http(status:)` and
`.network` to decide fatal vs. non-fatal, so don't flatten these into generic errors.

**Offline-first timer + deferred sync.** `TimerViewModel` can run a timer with no server round-trip
(`localRunStart`, persisted in `UserDefaults` so it survives a restart). On stop, or when any
online stop fails, the completed entry is queued to `PendingEntryStore` (JSON at
`~/Library/Application Support/Tracki/pending-entries.json`). `syncPending()` flushes the queue via
`backend.createCompleted(...)` on every successful (re)connect and on popover open; `TimerView`
shows an "Unsynced" section for anything still stuck. The running timer **always clears** so the UI
never gets stuck.

**Where persisted state lives** (four different stores — check all four when changing
login/session behaviour):

| What | Where |
|---|---|
| API token | Keychain, service `app.tracki.toggl` / account `api-token` (`KeychainHelper`) |
| Organization ID | `UserDefaults` key `organizationId` |
| In-progress offline run | `UserDefaults` key `localRunStart` (a `Date`) |
| Unsynced completed entries | `~/Library/Application Support/Tracki/pending-entries.json` |
| Reminder interval | `UserDefaults` key `reminderIntervalMinutes` (`0` = off) |

**Periodic reminders ("flyby").** While a timer runs, `ReminderScheduler` decides when to
interrupt and `FlybyPresenter` flies artwork across the top of the screen. Three things keep
this simple, and are worth preserving:
- The scheduler holds **no wall-clock state** — it works purely in *elapsed seconds*, which
  `tick()` already recomputes from the entry's start date every second. That's why reminders
  stay correct across restarts and machine sleep, and why missed periods **coalesce into one**
  alert instead of a burst.
- `startTicking()` / `stopTicking()` are the single arm/disarm choke points, so every way a
  run can begin (fresh start, offline start, restored local run, adopting an entry started
  elsewhere) is covered without touching each call site. Adopting a 2h-old entry aligns to the
  *next* boundary rather than firing immediately.
- The flyby window is borderless, `.screenSaver` level, `ignoresMouseEvents`, and shown with
  `orderFrontRegardless()` — click-through and **never steals focus**. Keep it that way; it's
  an ambient nudge, not a dialog.
- `FlybyArtwork` owns loading *and* import. Imported art is keyed with an **edge flood fill**,
  never a global white key — a global key punches holes in white parts *inside* a drawing
  (lettering, windows, highlights). Its pixel buffer is allocated with
  `UnsafeMutablePointer.allocate`, not `Array.withUnsafeMutableBytes`, because the `CGContext`
  must outlive the access; don't "simplify" that back to an Array closure.
- `scripts/make-flyby-asset.swift` runs the same algorithm from the CLI, for prepping the
  asset that ships in `Tracki/Resources/`. Verified byte-identical to the in-app path — if you
  change one, change both.

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
- **`--screenshot` short-circuits launch**: `applicationDidFinishLaunching` returns before
  `installEditMenu()` and `StatusBarController()`, so the screenshot path never creates a
  status item. `ScreenshotRenderer` also can't use `ImageRenderer` (it won't draw the
  AppKit-backed text field/pickers/button) — it renders into an offscreen `NSWindow` and
  `cacheDisplay`s it after a runloop delay. Keep that shape if you touch it.
- `docs/toggl-v2-api.md` names the classic host as `api.track.toggl.com`; the code actually
  uses `https://api.toggl.com/api/v9` (`TogglAPIClient.baseURL`). Trust the code.
