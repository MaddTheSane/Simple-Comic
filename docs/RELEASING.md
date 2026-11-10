# Releasing Simple Comic

Each release ships two ways from the same commit: the **Mac App Store** (uploaded and submitted for review through the App Store Connect API) and a **notarized, Developer-ID-signed zip** attached to a GitHub release on `MaddTheSane/Simple-Comic`.

## Conventions

- Marketing version `X.Y.Z`; build number is a single increasing integer (must exceed every build already uploaded to App Store Connect).
- Version bump lands via a PR into `arc` titled `Update marketing version to X.Y.Z.` (branch `App-Store-X.Y.Z-branch`).
- Tag and release title: `App-Store-X.Y.Z`. Asset: `Simple.Comic.X.Y.Z.zip`. The newest release is marked Latest.
- Everything is built and tagged from the merged `arc` commit, never from the PR branch.
- Remotes: `origin` is the nickv2002 fork, `upstream` is `MaddTheSane/Simple-Comic`, which hosts PRs and releases.

## One-time setup

- Developer ID Application certificate for team `3D9SMH4RWM` in the login keychain (`security find-identity -v -p codesigning`).
- `gh auth status` (push access to `upstream`), `op account list`, and Python 3 with the `cryptography` module (`pip3 install cryptography`).
- An App Store Connect API key stored in 1Password as an item named "App Store Connect API Key File" (the `.p8` attached as a file, an `issuer id` text field). The key is fetched live on every run into a 0700 temp dir and deleted on exit. Override with `OP_ACCOUNT`, `OP_VAULT`, `OP_ITEM`.
- Sparkle (direct-download auto-update): `brew install sparkle` for `sign_update`, plus a signing key in the login keychain under account `SimpleComic` (`generate_keys --account SimpleComic`; `generate_keys` is in the Sparkle release tarball or the SPM artifacts). Back it up in 1Password with `generate_keys --account SimpleComic -x <file>`. The public key lives in the `SPARKLE_PUBLIC_ED_KEY` build setting of the "Simple Comic Direct" target. Losing the private key means existing installs can never update.
- Cloud-managed distribution signing for App Store uploads uses the same key (`-allowProvisioningUpdates`); it may need a role above "Developer".

## Cutting a release

```sh
make release-dry-run VERSION=1.11.0    # build, notarize, verify locally; pushes nothing
make release VERSION=1.11.0            # full pipeline (BUILD defaults to latest uploaded + 1)
```

`make release` runs: preflight, then Claude Haiku (via `cldp`) drafts a one-line summary and the App Store "What's New" into `build/release-X.Y.Z/` and **stops for your approval** (edit those files first if needed). After approval: bump PR is opened and merged, tests run, the app is built/notarized/verified, uploaded to App Store Connect, attached to a new version record and submitted for review (manual release; pass `RELEASE_FLAGS="--release auto"` for automatic), then the tag is pushed and the GitHub release is created (Latest) with the zip, and the notarized app is installed to `/Applications`.

Run `make help` for the individual stages (`notes`, `archive`, `notarize`, `verify`, `upload`, `submit`, `tag`, `github-release`, `publish`, `install`); each is safe to retry. `make status` shows the versions and builds App Store Connect knows about.

## Two builds, one version

- `Simple Comic` (scheme/target) is the Mac App Store build and has no Sparkle.
- `Simple Comic Direct` is the notarized GitHub/Homebrew build: it embeds Sparkle, has a "Check for Updates…" menu item, and gets `SUFeedURL`/`SUPublicEDKey` injected into its Info.plist by a build phase.
- `scripts/sparkle_appcast.sh` signs the notarized zip and writes `dist/appcast.xml`. `release.sh` uploads it with the zip, and the app's feed URL is `https://github.com/MaddTheSane/Simple-Comic/releases/latest/download/appcast.xml`, so the newest release is always the feed.
- The Homebrew cask (`simple-comic` in homebrew-cask) is bumped automatically from our releases; keep the asset name `Simple.Comic.X.Y.Z.zip` and tag `App-Store-X.Y.Z` unchanged.

## Notes

- The GitHub release text says "Submitted to the Mac App Store"; edit it to "live in the Mac App Store" once review passes.
- Checks run on the zip: `codesign --verify --deep --strict`, `spctl --assess`, `stapler validate`, extraction with both `ditto` and `unzip`, and the app plus every extension reporting the expected version/build.
