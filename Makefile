SHELL := /bin/bash

XCODE_WRAPPER := ./Scripts/with-xcode-27-rc.sh
# xcodebuild cannot present first-use trust prompts in this noninteractive gate.
XCODEBUILD_OPTIONS := -skipMacroValidation
IPHONE_DESTINATION ?= platform=iOS Simulator,name=iPhone 17,OS=27.0
IPAD_DESTINATION ?= platform=iOS Simulator,name=iPad Pro 11-inch (M5),OS=27.0
# Xcode generates this aggregate scheme and its test action from Package.swift.
PACKAGE_WORKSPACE := Packages/ApplicationFoundation/.swiftpm/xcode/package.xcworkspace
PACKAGE_SCHEME := ApplicationFoundation-Package

.PHONY: all build lint test

all: lint build test

build:
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Debug -destination '$(IPHONE_DESTINATION)' build
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Release -destination '$(IPHONE_DESTINATION)' build
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Debug -destination '$(IPAD_DESTINATION)' build

test:
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Debug -destination '$(IPHONE_DESTINATION)' test
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace $(PACKAGE_WORKSPACE) -scheme $(PACKAGE_SCHEME) -configuration Debug -destination '$(IPHONE_DESTINATION)' test

lint:
	./Scripts/validate-release-identity.sh
	./Scripts/validate-whitespace.sh
	git diff --check
