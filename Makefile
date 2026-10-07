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

.PHONY: all build format lint lint-analyze test tools

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

lint: tools
	./Scripts/validate-release-identity.sh
	./Scripts/validate-whitespace.sh
	git diff --check
	bash ./Scripts/swift-tools.sh lint
	bash ./Scripts/run-swiftlint-analysis.sh

lint-analyze: tools
	bash ./Scripts/run-swiftlint-analysis.sh
