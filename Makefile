APP_NAME = RJ45Switch
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app
INSTALL_DIR = $(HOME)/Applications
LAUNCH_AGENT = com.rj45switch.plist
LAUNCH_AGENTS_DIR = $(HOME)/Library/LaunchAgents

.PHONY: build run install uninstall clean

build:
	swift build -c release

run: build
	$(BUILD_DIR)/$(APP_NAME)

bundle: build
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	@cp Info.plist $(APP_BUNDLE)/Contents/
	@echo "Built $(APP_BUNDLE)"

install: bundle
	@mkdir -p $(INSTALL_DIR)
	@rm -rf $(INSTALL_DIR)/$(APP_BUNDLE)
	@cp -R $(APP_BUNDLE) $(INSTALL_DIR)/
	@bash Scripts/install_launchagent.sh
	@echo "Installed to $(INSTALL_DIR)/$(APP_BUNDLE)"

uninstall:
	@rm -rf $(INSTALL_DIR)/$(APP_BUNDLE)
	@launchctl unload $(LAUNCH_AGENTS_DIR)/$(LAUNCH_AGENT) 2>/dev/null || true
	@rm -f $(LAUNCH_AGENTS_DIR)/$(LAUNCH_AGENT)
	@echo "Uninstalled $(APP_NAME)"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)
