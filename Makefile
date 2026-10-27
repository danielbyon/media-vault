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
# Recipes resolve helper paths from the Makefile selected by make. This
# top-level Makefile has no included files, so MAKEFILE_LIST contains one path;
# preserving it as quoted text supports checkout paths containing spaces. The
# cleanup helper rejects invocation outside its owning checkout before
# inspecting any artifact.

.PHONY: all build clean clean-test format lint lint-analyze test tools

all: lint build test

tools:
	bash ./Scripts/swift-tools.sh bootstrap

format: tools
	bash ./Scripts/swift-tools.sh format

# Build and test run against a temporary DerivedData directory that the recipe
# removes on exit. A later run receives a fresh path. A directory left behind by
# a killed run is preserved for inspection and is not inferred to be Make-owned.
build:
	@set -euo pipefail; \
	mkdir -p "$(CURDIR)/.build"; \
	derived_data=$$(mktemp -d "$(CURDIR)/.build/xcodebuild-build.XXXXXX"); \
	trap 'rm -rf -- "$$derived_data"' EXIT; \
	trap 'exit 143' TERM INT; \
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Debug -destination '$(IPHONE_DESTINATION)' -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$derived_data" build; \
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Release -destination '$(IPHONE_DESTINATION)' -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$derived_data" build; \
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Debug -destination '$(IPAD_DESTINATION)' -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$derived_data" build

test:
	@set -euo pipefail; \
	mkdir -p "$(CURDIR)/.build"; \
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

# Remove repository-local build products through the guarded cleanup helper.
# The helper deletes only paths emitted by this Makefile below .build. It keeps
# the .build parent and unknown contents, and preserves package-local build
# directories because no supported target establishes their ownership.
clean:
	@set -euo pipefail; \
	makefile_path="$(MAKEFILE_LIST)"; \
	makefile_path="$${makefile_path# }"; \
	makefile_path="$${makefile_path% }"; \
	script_directory=$$(dirname -- "$$makefile_path"); \
	bash "$$script_directory/Scripts/clean-build-artifacts.sh"

# Exercise the cleanup helper in disposable Git checkouts. These tests use no
# Xcode, SwiftPM, network access, or previously completed build.
clean-test:
	@set -euo pipefail; \
	makefile_path="$(MAKEFILE_LIST)"; \
	makefile_path="$${makefile_path# }"; \
	makefile_path="$${makefile_path% }"; \
	script_directory=$$(dirname -- "$$makefile_path"); \
	bash "$$script_directory/Scripts/tests/test-clean-build-artifacts.sh"
