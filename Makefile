SHELL := /bin/bash

XCODE_WRAPPER := ./Scripts/with-xcode-27-rc.sh
# xcodebuild cannot present first-use trust prompts in this noninteractive gate.
XCODEBUILD_OPTIONS := -skipMacroValidation
IPHONE_DESTINATION ?= platform=iOS Simulator,name=iPhone 17,OS=27.0
IPAD_DESTINATION ?= platform=iOS Simulator,name=iPad Pro 11-inch (M5),OS=27.0
# Xcode generates this aggregate scheme and its test action from Package.swift.
PACKAGE_WORKSPACE := Packages/ApplicationFoundation/.swiftpm/xcode/package.xcworkspace
PACKAGE_SCHEME := ApplicationFoundation-Package

MINT_VERSION := 0.18.0
MINT := ./.build/tools/mint/$(MINT_VERSION)/mint
MINT_ENV := env MINT_PATH="$(CURDIR)/.build/mint" MINT_LINK_PATH="$(CURDIR)/.build/mint/bin"
SWIFTFORMAT := $(XCODE_WRAPPER) $(MINT_ENV) $(MINT) run nicklockwood/SwiftFormat
SWIFTLINT := $(XCODE_WRAPPER) $(MINT_ENV) $(MINT) run realm/SwiftLint

.PHONY: all build format lint lint-analyze test tools

all: lint build test

tools:
	bash ./Scripts/bootstrap-swift-tools.sh

format: tools
	$(SWIFTFORMAT) App AppTests Packages --config .swiftformat

build:
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Debug -destination '$(IPHONE_DESTINATION)' build
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Release -destination '$(IPHONE_DESTINATION)' build
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Debug -destination '$(IPAD_DESTINATION)' build

test:
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Debug -destination '$(IPHONE_DESTINATION)' test
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace $(PACKAGE_WORKSPACE) -scheme $(PACKAGE_SCHEME) -configuration Debug -destination '$(IPHONE_DESTINATION)' test

lint: tools
	./Scripts/validate-release-identity.sh
	./Scripts/validate-whitespace.sh
	git diff --check
	$(SWIFTFORMAT) App AppTests Packages --config .swiftformat --lint
	$(SWIFTLINT) lint --config .swiftlint.yml
	bash ./Scripts/run-swiftlint-analysis.sh

lint-analyze: tools
	bash ./Scripts/run-swiftlint-analysis.sh
