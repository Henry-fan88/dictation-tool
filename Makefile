APP := .build/Dictation.app

.PHONY: build bundle run install debug clean

## build: compile the release binary
build:
	swift build -c release

## bundle: build and assemble Dictation.app
bundle: build
	bash scripts/bundle.sh

## run: bundle then launch the menu-bar app
run: bundle
	open $(APP)

## install: copy the app into /Applications and launch it
install: bundle
	rm -rf /Applications/Dictation.app
	cp -R $(APP) /Applications/Dictation.app
	open /Applications/Dictation.app

## debug: fast debug build (no bundle)
debug:
	swift build

## clean: remove build artifacts
clean:
	swift package clean
	rm -rf .build/Dictation.app
