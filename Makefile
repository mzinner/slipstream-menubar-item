APP := build/Slipstream Menubar.app

.PHONY: build test app run install clean

build:
	swift build

test:
	swift test

app:
	scripts/build-app.sh

# Opens the panel on launch, handy while working on it.
run: app
	open "$(APP)" --args --show-panel

install: app
	rm -rf "/Applications/Slipstream Menubar.app"
	cp -R "$(APP)" /Applications/

clean:
	rm -rf .build build
