# Common Simple Comic tasks. Run `make help` for the list.

SCHEME  ?= Simple Comic
PROJECT ?= SimpleComic.xcodeproj
# Kept outside the checkout so repeated builds are fast and the repo stays clean.
DERIVED ?= $(HOME)/Library/Caches/SimpleComic-DerivedData

.DEFAULT_GOAL := help
.PHONY: help build build-release test clean

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
