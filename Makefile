SHELL := /bin/bash

XCODE_WRAPPER := ./Scripts/with-xcode-27.2.sh
DESTINATION_VERIFIER := ./Scripts/verify-xcode-27.2-destination.sh
# CI may supply verified device IDs; local runs resolve one per destination.
VERIFIED_SIMULATOR_UDID ?=
VERIFIED_IPAD_SIMULATOR_UDID ?=
# xcodebuild cannot present first-use trust prompts in this noninteractive gate.
XCODEBUILD_OPTIONS := -skipMacroValidation
IPHONE_DESTINATION ?= platform=iOS Simulator,name=iPhone 17,OS=27.2
IPAD_DESTINATION ?= platform=iOS Simulator,name=iPad Pro 11-inch (M5),OS=27.2
# Canonical snapshot destination. The iPad mini was considered, but its
# availability on the xcode-27 CI runner is unverified. Local and CI runs use
# one model consistently: iPad Pro 11-inch (M5), iOS 27.2, at 2x scale.
SNAPSHOT_DESTINATION ?= $(IPAD_DESTINATION)
# Snapshot suites are kept out of the iPhone gate. The App scheme owns the root
# surface and hosted privacy-presentation snapshots; the package scheme owns five snapshot suites.
APP_SNAPSHOT_SUITE := AppTests/RootSurfaceSnapshotTests
APP_HOSTED_ROOT_PRESENTATION_SNAPSHOT_TEST := AppHostedTests/AppHostedUITests/ScenePrivacyCoverTests/rootPresentationSnapshotsCoverPrimaryShellStates
APP_HOSTED_PRIVACY_OCCLUSION_TEST := AppHostedTests/AppHostedUITests/ScenePrivacyCoverTests/rootPrivacyCoverSynchronouslyOccludesPrivateSentinel(_:)
PACKAGE_SNAPSHOT_SUITES := \
	AppFeatureTests/VaultFeatureViewSnapshotTests \
	CalculatorFeatureTests/CalculatorViewSnapshotTests \
	MediaLibraryTests/MediaLibrarySnapshotTests \
	BrowserFeatureTests/BrowserViewSnapshotTests \
	PresentationSupportTests/ScenePrivacyCoverCalculatorSnapshotTests
# Optional external directory for preserving xcresult bundles. Each test
# invocation writes a bundle below its temporary test root; the bundle is
# copied here before the temporary root is removed.
TEST_RESULTS_DIRECTORY ?=
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

.PHONY: all build clean clean-test destination-test format lint lint-analyze test test-snapshots tools verify-test-destination verify-snapshot-destination

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
	simulator_udid=$$($(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(IPHONE_DESTINATION)' '$(VERIFIED_SIMULATOR_UDID)' | tail -n 1); \
	ipad_simulator_udid=$$($(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(IPAD_DESTINATION)' '$(VERIFIED_IPAD_SIMULATOR_UDID)' | tail -n 1); \
	mkdir -p "$(CURDIR)/.build"; \
	test_root=$$(mktemp -d "$(CURDIR)/.build/xcodebuild-test.XXXXXX"); \
	test_results=""; \
	if [[ -n "$(TEST_RESULTS_DIRECTORY)" ]]; then \
		mkdir -p "$(TEST_RESULTS_DIRECTORY)"; \
		test_results=$$(mktemp -d "$(TEST_RESULTS_DIRECTORY)/xcodebuild-test.XXXXXX"); \
	fi; \
	preserve_results() { \
		status=$$?; \
		if [[ -n "$$test_results" ]]; then \
			for result in "$$test_root"/*.xcresult; do \
				[[ -d "$$result" ]] || continue; \
				cp -R "$$result" "$$test_results/" || printf 'failed to preserve %s\n' "$$result" >&2; \
			done; \
		fi; \
		rm -rf -- "$$test_root"; \
		trap - EXIT; \
		exit "$$status"; \
	}; \
	trap preserve_results EXIT; \
	trap 'exit 143' TERM INT; \
	assert_tests_ran() { \
		label="$$1"; bundle="$$2"; \
		if [[ ! -d "$$bundle" ]]; then \
			printf 'test results bundle missing for %s: %s\n' "$$label" "$$bundle" >&2; \
			return 1; \
		fi; \
		if ! summary=$$($(XCODE_WRAPPER) xcrun xcresulttool get test-results summary --path "$$bundle" --compact 2>&1); then \
			printf 'test results summary unreadable for %s: %s\n' "$$label" "$$bundle" >&2; \
			printf '%s\n' "$$summary" >&2; \
			return 1; \
		fi; \
		count=$$(printf '%s\n' "$$summary" | sed -n 's/.*"totalTestCount"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1); \
		if [[ -z "$$count" ]]; then \
			printf 'test results summary missing totalTestCount for %s: %s\n' "$$label" "$$bundle" >&2; \
			return 1; \
		fi; \
		if [[ ! "$$count" =~ ^[1-9][0-9]*$$ ]]; then \
			printf 'zero tests recorded for %s: %s totalTestCount=%s\n' "$$label" "$$bundle" "$$count" >&2; \
			return 1; \
		fi; \
		printf '%s: %s tests\n' "$$label" "$$count"; \
	}; \
	$(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(IPHONE_DESTINATION)' "$$simulator_udid" -- xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Debug -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$test_root/App" -resultBundlePath "$$test_root/App.xcresult" -skip-testing:$(APP_SNAPSHOT_SUITE) -skip-testing:'$(APP_HOSTED_ROOT_PRESENTATION_SNAPSHOT_TEST)()' test; \
	assert_tests_ran App "$$test_root/App.xcresult"; \
	$(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(IPHONE_DESTINATION)' "$$simulator_udid" -- xcodebuild $(XCODEBUILD_OPTIONS) -workspace $(PACKAGE_WORKSPACE) -scheme $(PACKAGE_SCHEME) -configuration Debug -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$test_root/ApplicationFoundation" -resultBundlePath "$$test_root/ApplicationFoundation.xcresult" $(foreach suite,$(PACKAGE_SNAPSHOT_SUITES),-skip-testing:$(suite)) test; \
	assert_tests_ran ApplicationFoundation "$$test_root/ApplicationFoundation.xcresult"; \
	$(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(IPAD_DESTINATION)' "$$ipad_simulator_udid" -- xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Debug -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$test_root/App-iPadPrivacy" -resultBundlePath "$$test_root/App-iPadPrivacy.xcresult" -parallel-testing-enabled NO -only-testing:'$(APP_HOSTED_PRIVACY_OCCLUSION_TEST)' test; \
	assert_tests_ran App-iPad-privacy "$$test_root/App-iPadPrivacy.xcresult"

# Exercise the native presentation snapshot suites on the canonical 2x iPad.
# UIKit lifecycle protection remains covered by behavioral tests in `make test`.
# Both schemes run even when the first suite fails so the complete failure
# inventory is available. The canonical 2x reference baseline is required, and
# exact snapshot comparisons must pass.
test-snapshots:
	@set -euo pipefail; \
	simulator_udid=$$($(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(SNAPSHOT_DESTINATION)' '$(VERIFIED_SIMULATOR_UDID)' | tail -n 1); \
	mkdir -p "$(CURDIR)/.build"; \
	test_root=$$(mktemp -d "$(CURDIR)/.build/xcodebuild-snapshot-test.XXXXXX"); \
	test_results=""; \
	if [[ -n "$(TEST_RESULTS_DIRECTORY)" ]]; then \
		mkdir -p "$(TEST_RESULTS_DIRECTORY)"; \
		test_results=$$(mktemp -d "$(TEST_RESULTS_DIRECTORY)/xcodebuild-snapshot-test.XXXXXX"); \
	fi; \
	preserve_results() { \
		status=$$?; \
		if [[ -n "$$test_results" ]]; then \
			for result in "$$test_root"/*.xcresult; do \
				[[ -d "$$result" ]] || continue; \
				cp -R "$$result" "$$test_results/" || printf 'failed to preserve %s\n' "$$result" >&2; \
			done; \
		fi; \
		rm -rf -- "$$test_root"; \
		trap - EXIT; \
		exit "$$status"; \
	}; \
	trap preserve_results EXIT; \
	trap 'exit 143' TERM INT; \
	status=0; \
	failure_summary=""; \
	remember_failure() { \
		label="$$1"; \
		failure_status="$$2"; \
		if (( failure_status != 0 )); then \
			failure_summary+="$${label}=$${failure_status} "; \
			if (( status == 0 )); then \
				status=$$failure_status; \
			fi; \
		fi; \
		return 0; \
	}; \
	assert_tests_ran() { \
		label="$$1"; bundle="$$2"; \
		if [[ ! -d "$$bundle" ]]; then \
			printf 'test results bundle missing %s: %s\n' "$$label" "$$bundle" >&2; \
			return 1; \
		fi; \
		if ! summary=$$($(XCODE_WRAPPER) xcrun xcresulttool get test-results summary --path "$$bundle" --compact 2>&1); then \
			printf 'test results summary unreadable %s: %s\n' "$$label" "$$bundle" >&2; \
			printf '%s\n' "$$summary" >&2; \
			return 1; \
		fi; \
		count=""; \
		if [[ "$$summary" =~ \"totalTestCount\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then \
			count="$${BASH_REMATCH[1]}"; \
		fi; \
		if [[ -z "$$count" ]]; then \
			printf 'test results summary missing totalTestCount %s: %s\n' "$$label" "$$bundle" >&2; \
			return 1; \
		fi; \
		if [[ ! "$$count" =~ ^[1-9][0-9]*$$ ]]; then \
			printf 'zero tests recorded %s: %s totalTestCount=%s\n' "$$label" "$$bundle" "$$count" >&2; \
			return 1; \
		fi; \
		printf '%s: %s tests\n' "$$label" "$$count"; \
	}; \
	app_xcode_status=0; \
	TEST_RUNNER_SNAPSHOT_TESTING_RECORD=never $(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(SNAPSHOT_DESTINATION)' "$$simulator_udid" -- xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Debug -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$test_root/App" -resultBundlePath "$$test_root/App.xcresult" -only-testing:$(APP_SNAPSHOT_SUITE) -only-testing:'$(APP_HOSTED_ROOT_PRESENTATION_SNAPSHOT_TEST)()' test || app_xcode_status=$$?; \
	app_count_status=0; \
	assert_tests_ran App "$$test_root/App.xcresult" || app_count_status=$$?; \
	remember_failure App-xcodebuild "$$app_xcode_status"; \
	remember_failure App-test-count "$$app_count_status"; \
	package_xcode_status=0; \
	TEST_RUNNER_SNAPSHOT_TESTING_RECORD=never $(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(SNAPSHOT_DESTINATION)' "$$simulator_udid" -- xcodebuild $(XCODEBUILD_OPTIONS) -workspace $(PACKAGE_WORKSPACE) -scheme $(PACKAGE_SCHEME) -configuration Debug -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$test_root/ApplicationFoundation" -resultBundlePath "$$test_root/ApplicationFoundation.xcresult" $(foreach suite,$(PACKAGE_SNAPSHOT_SUITES),-only-testing:$(suite)) test || package_xcode_status=$$?; \
	package_count_status=0; \
	assert_tests_ran ApplicationFoundation "$$test_root/ApplicationFoundation.xcresult" || package_count_status=$$?; \
	remember_failure ApplicationFoundation-xcodebuild "$$package_xcode_status"; \
	remember_failure ApplicationFoundation-test-count "$$package_count_status"; \
	if [[ -n "$$failure_summary" ]]; then \
		printf 'test-snapshots failures: %s\n' "$$failure_summary" >&2; \
	fi; \
	exit "$$status"

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

# Read canonical destinations from Make for both CI preflight and local checks.
verify-test-destination:
	$(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(IPHONE_DESTINATION)' '$(VERIFIED_SIMULATOR_UDID)'

verify-snapshot-destination:
	$(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(SNAPSHOT_DESTINATION)' '$(VERIFIED_SIMULATOR_UDID)'

# Synthetic inventories exercise the resolver and actual Make execution arguments.
destination-test:
	python3 ./Scripts/tests/test-xcode-27.2-destination.py
