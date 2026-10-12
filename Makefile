SHELL := /bin/bash

XCODE_WRAPPER := ./Scripts/with-xcode-27-rc.sh
# xcodebuild cannot present first-use trust prompts in this noninteractive gate.
XCODEBUILD_OPTIONS := -skipMacroValidation
IPHONE_DESTINATION ?= platform=iOS Simulator,name=iPhone 17,OS=27.0
IPAD_DESTINATION ?= platform=iOS Simulator,name=iPad Pro 11-inch (M5),OS=27.0
# Xcode generates this aggregate scheme and its test action from Package.swift.
PACKAGE_WORKSPACE := Packages/ApplicationFoundation/.swiftpm/xcode/package.xcworkspace
PACKAGE_SCHEME := ApplicationFoundation-Package
# Share one package checkout cache across runs so isolated DerivedData
# directories do not clone dependencies again. Only package sources are
# shared; build products stay in the per-run temporary DerivedData directory.
SOURCE_PACKAGES_DIRECTORY := $(CURDIR)/.build/SourcePackages

.PHONY: all build clean format lint lint-analyze test tools spike-webpage-download spike-browser-urlsession spike-browser-wkdownload spike-browser-save-to-vault spike-browser-receipt-lifecycle

all: lint build test

tools:
	bash ./Scripts/swift-tools.sh bootstrap

format: tools
	bash ./Scripts/swift-tools.sh format

# Build and test run against a temporary DerivedData directory that is deleted
# when the recipe exits, including failure paths, so repeated or concurrent
# runs cannot collide on shared build state or exhaust disk. Directories left
# behind by runs that were killed outright are pruned after a day.
build:
	@set -euo pipefail; \
	mkdir -p "$(CURDIR)/.build"; \
	find "$(CURDIR)/.build" -maxdepth 1 -type d -name 'xcodebuild-*' -mtime +0 -exec rm -rf -- {} +; \
	derived_data=$$(mktemp -d "$(CURDIR)/.build/xcodebuild-build.XXXXXX"); \
	trap 'rm -rf -- "$$derived_data"' EXIT; \
	trap 'exit 143' TERM INT; \
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Debug -destination '$(IPHONE_DESTINATION)' -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$derived_data" build; \
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Release -destination '$(IPHONE_DESTINATION)' -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$derived_data" build; \
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Debug -destination '$(IPAD_DESTINATION)' -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$derived_data" build

test:
	@set -euo pipefail; \
	mkdir -p "$(CURDIR)/.build"; \
	find "$(CURDIR)/.build" -maxdepth 1 -type d -name 'xcodebuild-*' -mtime +0 -exec rm -rf -- {} +; \
	test_root=$$(mktemp -d "$(CURDIR)/.build/xcodebuild-test.XXXXXX"); \
	trap 'rm -rf -- "$$test_root"' EXIT; \
	trap 'exit 143' TERM INT; \
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Debug -destination '$(IPHONE_DESTINATION)' -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$test_root/App" test; \
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace $(PACKAGE_WORKSPACE) -scheme $(PACKAGE_SCHEME) -configuration Debug -destination '$(IPHONE_DESTINATION)' -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$test_root/ApplicationFoundation" test

# Disposable runtime experiment. Keep this scheme outside the shipping App
# scheme and the normal build/test gates; invoke it only when validating the
# WebPage download lifecycle spike explicitly. Preserve its test result bundles
# under ignored .build output so validation evidence survives temporary build cleanup.
spike-webpage-download:
	@set -euo pipefail; \
	mkdir -p "$(CURDIR)/.build"; \
	derived_data=$$(mktemp -d "$(CURDIR)/.build/xcodebuild-spike-webpage-download.XXXXXX"); \
	evidence_dir=$$(mktemp -d "$(CURDIR)/.build/browser-spike-1-results.XXXXXX"); \
	trap 'rm -rf -- "$$derived_data"' EXIT; \
	trap 'exit 143' TERM INT; \
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme WebPageDownloadSpike -configuration Debug -destination '$(IPHONE_DESTINATION)' -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$derived_data" build; \
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme WebPageDownloadSpike -configuration Debug -destination '$(IPHONE_DESTINATION)' -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$derived_data" -resultBundlePath "$$evidence_dir/iphone.xcresult" test; \
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme WebPageDownloadSpike -configuration Debug -destination '$(IPAD_DESTINATION)' -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$derived_data" -resultBundlePath "$$evidence_dir/ipad.xcresult" test

# Disposable Spike 2 runtime experiment. The dedicated scheme stays outside
# the shipping App scheme and the normal build/test gates, and the fixture
# server runs as a separate host process because an in-app server cannot
# survive app suspension or termination.
spike-browser-urlsession:
	./Prototypes/BrowserURLSessionSpike/run-spike.sh

spike-browser-wkdownload:
	./Prototypes/BrowserWKDownloadSpike/run-spike.sh

# Run the disposable Browser Spike 4 matrix and the real SQLite journal handoff
# on the supported iPhone and iPadOS 27 simulator runtimes.
spike-browser-save-to-vault:
	bash ./Prototypes/BrowserSaveToVaultSpike/run-spike.sh

# Disposable Spike 6: a separate host, fixture, and package-test handoff.
# The runner writes only sanitized evidence below .build and fails on assertions.
spike-browser-receipt-lifecycle:
	./Prototypes/BrowserReceiptLifecycleSpike/run-spike.sh

lint: tools
	./Scripts/validate-release-identity.sh
	./Scripts/validate-whitespace.sh
	git diff --check
	bash ./Scripts/swift-tools.sh lint
	bash ./Scripts/run-swiftlint-analysis.sh

lint-analyze: tools
	bash ./Scripts/run-swiftlint-analysis.sh

# Delete build output and regenerable caches: per-run DerivedData and the
# shared package checkout cache under .build, SwiftPM/Xcode build directories
# inside packages, per-user Xcode state, and Finder metadata. None of it is
# tracked by git, and `make all` recreates whatever it needs. The toolchain
# bootstrap in .tools, the CodeGraph index in .codegraph, .chatgpt
# orchestration state, and linked worktrees in .worktrees are left in place.
clean:
	@set -euo pipefail; \
	rm -rf -- "$(CURDIR)/.build"; \
	rm -rf -- "$(CURDIR)"/Packages/*/.build "$(CURDIR)"/Packages/*/build; \
	find "$(CURDIR)" -type d \( -name .git -o -name .worktrees \) -prune \
		-o -type d -name xcuserdata -prune -exec rm -rf -- {} + \
		-o -type f -name .DS_Store -exec rm -f -- {} +
