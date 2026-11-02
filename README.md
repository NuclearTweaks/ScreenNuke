# ScreenNuke

**Shrink the whole UI so more content fits on screen — continuously, from a slider.**

Install: add `https://nucleartweaks.github.io/` in Sileo/Cydia (rootless, iOS 15+).

## Why

Phone screens are packed with too little content. Apple noticed exactly once,
offered exactly one option, and froze it: *Display Zoom → More Space* — one
preset, on a few models, forever. Meanwhile the iOS 8 era proved the concept
was lovely: the same hardware rendering a denser layout let you see vastly
more per screen. Every mail app, feed, and settings list instantly feels like
a tablet app when the UI stops hogging pixels.

ScreenNuke is More Space, unlocked: a continuous slider from 100 % (stock)
down to 55 % (tiny), system-wide, every app, no blur, no magnifier-y
zooming, no fixed presets.

## What it does

- **One slider**: everything — text, icons, list rows, buttons, keyboards,
  panels — scales down together. At 85 % you get ~31 % more content per
  screen; at 55 %, ~100 % more (double the content area).
- **Pixel-exact**: not a magnifier and not a downscaled screenshot. Layout
  happens on the denser point grid and renders into the same physical pixels
  — glyphs stay crisp, like feeding 1080p output into a panel that simply
  *is* those pixels.
- **System-wide**: SpringBoard (more icon slots per page), Settings, Apple
  apps, App Store apps, keyboards, alerts — any process that draws UI.
- **Bonus switch**: *Extra-small system text* pins the content-size category
  to Extra Small on top of the slider, dropping dynamic text styles to their
  smallest tier for maximum density.

## How it works

iOS lays everything out in *points*; a point becomes *scale* pixels
(`[UIScreen mainScreen].scale`). The two quantities that decide how much fits
on screen — how many points there are, and how many pixels a point costs —
are read from `UIScreen` by every process in the system.

ScreenNuke hooks the main screen's `scale`, `nativeScale`, `bounds` (and
`applicationAvailableBounds`) in every GUI process and tells one coherent,
self-consistent lie:

```
effectiveScale  = realScale  × f      (f = density slider, 0.55…1.00)
effectiveBounds = realBounds ÷ f
```

`bounds × scale` still equals the physical pixel size exactly — the lie is
internally consistent, so CoreGraphics rasterizes at the correct resolution
and nothing is resampled. Every app then re-lays out on the bigger point
canvas, which is precisely "everything smaller, more per screen."

The real values are snapshotted lazily on the first hooked read (after the
window-server connection is up, before any window exists) and all later reads
answer from the snapshot — no recursion, no drift, no dependence on read
order. (UIKit asserts if a tweak calls `[UIScreen mainScreen]` itself during
a launch transition — so ScreenNuke hooks `+mainScreen` and captures the
instance every time UIKit legitimately calls it.)

On iOS 18+ the *window* doesn't follow `UIScreen` — apps size themselves from
their scene's coordinate space (`_UIWindowSceneCoordinateSpace`, measured
live with the stock window stubbornly 375 pt wide while the screen lied).
ScreenNuke extends the identical lie to the scene space's `bounds`/`scale`
and the scene geometry's `systemFrame`, and only when the rect IS the whole
stock screen — split-view and PiP scenes pass through untouched. That is what
actually re-lays apps out: measured on the iOS 27 simulator, `keyWindow`
grows to 441 × 955 pt, Settings shows a ninth row that stock clips behind
the search bar, and the A/B screenshot verdict is "crisp, complete, no
blur — a true re-layout at native resolution."

Display-infrastructure processes are excluded and see the truth: `backboardd`
& co (compositing) and `PosterBoard` (it verifies screen bounds against its
own hard-coded table of stock device metrics and traps on deviation; it
degrades to default poster behaviour while everything else wins).

Preference changes post a Darwin notification; every running process updates
its factor in place. Apps pick it up live on the next re-layout (new scene,
rotation); a respring re-applies to everything at once.

**Bonus**: with the tiny-text switch on, `-[UIApplication
preferredContentSizeCategory]` answers `UICTContentSizeCategoryXS`, so
`preferredFontForTextStyle:` users (nearly all system and many third-party
text) fall to their smallest tier — stacked on top of the density slider.

## Preferences

Settings → ScreenNuke:

| Control | Key | Range | Default |
|---|---|---|---|
| UI size slider | `density` | 1.00 → 0.55 | 0.85 |
| Extra-small system text | `tinyText` | on/off | off |

Domain: `com.nucleartweaks.screen-nuke`. Slider position maps
logarithmically so fine control lives at both ends.

## Notes

- The slider takes effect in newly launched apps immediately; **respring** to
  force every already-running app onto the new grid at once.
- Apps that hard-code device metrics (rare; mostly old games) may not
  re-layout perfectly — background them and reopen.
- Verified on the iOS 27 jailbroken simulator (rootful loader). On device
  (rootless, `/var/jb`) the same code path runs; `Depends: mobilesubstrate`
  is resolved at runtime (dlsym fallback across libhooker/ElleKit/Substrate).

## Development

Org-standard scaffold — pipeline lives in `$ORG/.github` (reusable `tweak-ci.yml`).

* Local sim loop: `tools/sim-test.sh ScreenNuke` from the workspace root (Mac + JB-13mini; CI never builds for sim).
* Release: push to `main` → CI opens a release PR → merge → GitHub Release + APT repo update.
* `Package:` id `com.nucleartweaks.screen-nuke` is immutable after the first release. See the org KB (`meta` repo → knowledge/pitfalls.md).

## Build

```sh
make package FINALPACKAGE=1          # rootless device deb (CI)
../tools/sim-test.sh ScreenNuke      # local jailbroken-sim loop (Mac host)
```

## License

MIT
