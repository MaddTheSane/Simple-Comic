# Common Simple Comic tasks. Run `make help` for the list.

SCHEME  ?= Simple Comic
PROJECT ?= SimpleComic.xcodeproj
# Kept outside the checkout so repeated builds are fast and the repo stays clean.
DERIVED ?= $(HOME)/Library/Caches/SimpleComic-DerivedData

.DEFAULT_GOAL := help
.PHONY: help build build-release test clean submodules run analyze \
	version preflight notes archive build-dist notarize verify upload upload-dry-run submit status tag github-release publish install release release-dry-run clean-release

help: ## List the available targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

build: ## Debug build
	xcodebuild -project $(PROJECT) -scheme "$(SCHEME)" -configuration Debug -derivedDataPath $(DERIVED) build

build-release: ## Unsigned Release build (checks that Release links)
	xcodebuild -project $(PROJECT) -scheme "$(SCHEME)" -configuration Release -derivedDataPath $(DERIVED)-release build CODE_SIGNING_ALLOWED=NO

test: ## Run the unit tests
	xcodebuild test -project $(PROJECT) -scheme "$(SCHEME)" -derivedDataPath $(DERIVED)

clean: ## Remove build/
	rm -rf build

# ---- development ----------------------------------------------------------

submodules: ## Init/update git submodules (XADMaster etc.)
	git submodule update --init --recursive

run: ## Open the most recent Debug build
	open "$(DERIVED)/Build/Products/Debug/Simple Comic.app"

analyze: ## Static analysis of the app target
	xcodebuild analyze -project $(PROJECT) -scheme "$(SCHEME)" -derivedDataPath $(DERIVED)

# ---- release pipeline (see docs/RELEASING.md) -------------------------------
# VERSION=1.11.0 [BUILD=362]; BUILD defaults to the latest uploaded build + 1.

VERSION ?= $(shell . scripts/lib.sh; current_version | awk '{print $$1}')
RELEASE_FLAGS ?=

version: ## Print current version/build and the highest build on App Store Connect
	@. scripts/lib.sh; echo "project: $$(current_version)"; echo "latest uploaded build: $$(asc_latest_build)"

status: ## Recent App Store Connect versions and builds
	@. scripts/lib.sh; asc_key_setup; python3 -I scripts/asc.py status

preflight: ## Check signing identity, gh and 1Password auth
	@security find-identity -v -p codesigning | grep -q "Developer ID Application" || (echo "no Developer ID identity"; exit 1)
	@gh auth status >/dev/null && op account list >/dev/null && echo "preflight ok"

notes: ## Draft release notes with Haiku (VERSION=x.y.z [PREV=App-Store-a.b.c])
	scripts/release_summary.sh "$(VERSION)" "$(PREV)" build/release-$(VERSION)

archive: ## Developer-ID signed export in build/export
	scripts/build_release.sh

build-dist: archive ## Alias for archive

notarize: ## Notarize, staple and zip into dist/ (VERSION=x.y.z)
	scripts/notarize.sh "$(VERSION)"

verify: ## Verify dist zip: signature, Gatekeeper, staple, versions (VERSION BUILD)
	scripts/verify_release.sh "dist/Simple.Comic.$(VERSION).zip" "$(VERSION)" "$(BUILD)"

upload-dry-run: ## Archive + export the App Store build locally, upload nothing
	scripts/upload_app_store.sh export

upload: ## Archive and upload the build to App Store Connect
	scripts/upload_app_store.sh upload

submit: ## Set What's New, attach build and submit for review (VERSION BUILD)
	@. scripts/lib.sh; asc_key_setup; python3 -I scripts/asc.py wait-build "$(BUILD)" && \
	python3 -I scripts/asc.py submit --version "$(VERSION)" --build "$(BUILD)" --whats-new-file build/release-$(VERSION)/whats-new.txt

tag: ## Tag the current commit App-Store-VERSION and push to upstream
	git tag "App-Store-$(VERSION)" && git push upstream "App-Store-$(VERSION)"

github-release: ## Create a draft GitHub release with the notarized zip
	gh release create "App-Store-$(VERSION)" "dist/Simple.Comic.$(VERSION).zip" --repo MaddTheSane/Simple-Comic \
		--title "App-Store-$(VERSION)" --draft --generate-notes --notes-file build/release-$(VERSION)/summary.txt

publish: ## Un-draft the release and mark it Latest
	gh release edit "App-Store-$(VERSION)" --repo MaddTheSane/Simple-Comic --draft=false --latest

install: ## Install the notarized build to /Applications
	scripts/install_local.sh

release: ## Full pipeline (VERSION=x.y.z [BUILD=n]); one approval stop after Haiku drafts the notes
	VERSION="$(VERSION)" scripts/release.sh $(RELEASE_FLAGS)

release-dry-run: ## Everything except bump PR, upload, tag and publish
	VERSION="$(VERSION)" scripts/release.sh --dry-run $(RELEASE_FLAGS)

clean-release: clean ## Clear build/ (dist/ zips are kept on purpose)
