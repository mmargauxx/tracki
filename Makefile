APP      := Tracki
CONFIG   := release
BINARY   := .build/$(CONFIG)/$(APP)
BUNDLE   := dist/$(APP).app
CONTENTS := $(BUNDLE)/Contents

INSTALL_DIR := /Applications

.PHONY: build bundle run install screenshot clean

build:
	swift build -c $(CONFIG)

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BINARY) $(CONTENTS)/MacOS/$(APP)
	cp Tracki/Info.plist $(CONTENTS)/Info.plist
	cp Tracki/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	printf 'APPL????' > $(CONTENTS)/PkgInfo
	codesign --force --sign - --entitlements Tracki.entitlements $(BUNDLE)
	@echo "Built $(BUNDLE)"

run: bundle
	open $(BUNDLE)

# Install into /Applications so Tracki is launchable from Spotlight, Launchpad and Finder.
install: bundle
	-osascript -e 'quit app "$(APP)"' 2>/dev/null || true
	rm -rf "$(INSTALL_DIR)/$(APP).app"
	cp -R $(BUNDLE) "$(INSTALL_DIR)/$(APP).app"
	codesign --force --sign - --entitlements Tracki.entitlements "$(INSTALL_DIR)/$(APP).app"
	@echo "Installed $(INSTALL_DIR)/$(APP).app — launch it from Spotlight (⌘Space → \"Tracki\")"

# Render docs/screenshot.png from the real UI (offscreen render, no live app needed).
screenshot: build
	.build/$(CONFIG)/$(APP) --screenshot docs/screenshot.png

clean:
	rm -rf .build dist
