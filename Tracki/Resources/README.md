# Flyby artwork

Drop the flyby image here as `flyby.png` (`.gif`, `.jpg`, and `.pdf` also work — see
`FlybyAsset.extensions`). `make bundle` copies everything in this folder into
`Tracki.app/Contents/Resources/`, and `FlybyAsset.load()` picks it up from there.

Two things to know:

- **This folder is excluded from the SPM target** (`exclude:` in `Package.swift`). It holds
  no Swift sources; adding one here would silently not be compiled.
- **For iterating on the art without rebuilding**, drop the file at
  `~/Library/Application Support/Tracki/flyby.png` instead. That path is checked first and
  wins over the bundled copy, so the next flyby picks it up immediately.

With no artwork in either location the flyby falls back to a plain text card, so reminders
keep working.

Sizing: the image is scaled to fit `FlybyPresenter.artworkHeight` (132pt) preserving aspect
ratio, so ship it at 2× (~264pt tall) or larger for Retina. Transparent background — the
flyby window is fully transparent and click-through.

Orientation: the artwork is assumed to face **left**, because the flyby travels right-to-left
across the top of the screen. If it faces right, flip the `start`/`end` frames in
`FlybyPresenter.show`.

## Preparing new artwork

Source art usually arrives as a **white-background** PNG with generous margins. Both are
problems here: the flyby window is fully transparent, so an opaque background flies a white
rectangle across the screen, and the margin eats into the 132pt height budget so the drawing
renders small.

`scripts/make-flyby-asset.swift` handles both:

```sh
swift scripts/make-flyby-asset.swift <source.png> Tracki/Resources/flyby.png
```

It keys out the background with an **edge flood fill** (not a global white key — that would
punch holes in white parts *inside* the drawing, like the cockpit window and the "WFP"
lettering), softens the anti-aliased edge pixels by luminance to kill the halo, then crops to
the content bounds. The current `flyby.png` went 735×682 → 265×253 that way.

Check new art on a dark background before shipping it — a white fringe is invisible against
a light desktop and obvious against a dark one.
