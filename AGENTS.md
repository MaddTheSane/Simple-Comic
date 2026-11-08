# Simple Comic — agent notes

macOS comic reader (Objective-C/Swift, AppKit) plus QuickComic Quick Look/thumbnail extensions. Fork of arauchfuss/Simple-Comic maintained by MaddTheSane; this checkout's `origin` is nickv2002's fork and `upstream` is `MaddTheSane/Simple-Comic`.

## Build and test

- `git submodule update --init --recursive` (or `make submodules`) before building; `Vendor/XADMaster` provides archive reading.
- `make build` / `make test` / `make build-release`; `make help` lists everything. Scheme: "Simple Comic", project `SimpleComic.xcodeproj`. DerivedData lives in `~/Library/Caches/SimpleComic-DerivedData`.
- Layout: `Classes/` app code, `QuickComic/` extensions, `Resources/`, `Vendor/` submodules, `App Review Info/` reviewer note + public-domain fixture.

## Releases

See `docs/RELEASING.md`. Short version: `make release VERSION=X.Y.Z` (or `make release-dry-run`); tags `App-Store-X.Y.Z`, asset `Simple.Comic.X.Y.Z.zip`, published on `MaddTheSane/Simple-Comic`; version bump PR into `arc`; build number is a single increasing integer checked against App Store Connect. Signing/notarization uses a Developer ID cert and an App Store Connect API key fetched from 1Password at run time (never stored). Pushing, publishing and submitting need the owner's explicit go-ahead for each release.

## Testing hygiene

- Only the public-domain Jessie James comic may be committed as a fixture; ask the owner for RAR/other samples.
- Tests must not prompt (no modal panels); keep test comics off Desktop/Documents to avoid TCC prompts.
- Check `~/Library/Logs/DiagnosticReports` for crashes after running the app.
- For perf work, judge by visible stalls or clear progress UI rather than internal timings.

## Housekeeping

`dist/` (notarized zips), `build/` and `.context/` (local agent notes) are git-ignored. Do not add a CLAUDE.md; keep agent info here.
