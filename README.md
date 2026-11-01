# ScreenNuke

Shrink the whole UI — continuous More-Space mode: slide everything smaller and fit far more on screen, iOS-8-style.

Install: add `https://nucleartweaks.github.io/` in Sileo/Cydia (rootless, iOS 15+).

## Development

Org-standard scaffold — pipeline lives in `$ORG/.github` (reusable `tweak-ci.yml`).

* Local sim loop: `tools/sim-test.sh ScreenNuke` from the workspace root (Mac + JB-13mini; CI never builds for sim).
* Release: push to `main` → CI opens a release PR → merge → GitHub Release + APT repo update.
* `Package:` id `com.nucleartweaks.screen-nuke` is immutable after the first release. See the org KB (`meta` repo → knowledge/pitfalls.md).
