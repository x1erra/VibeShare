.PHONY: help router swift build app install run clean test fetch-provider

GO ?= $(shell command -v go || echo /opt/homebrew/bin/go)

help: ## Show this help
	@echo "VibeShare — share your AI subscriptions with friends, peer-to-peer"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

fetch-provider: ## Download the cli-proxy-api provider binary into Resources
	@./scripts/fetch-cliproxyapi.sh

router: ## Build the Go router into Swift Resources
	@echo "🔨 Building vibeshare-router..."
	@rm -f src/Sources/Resources/vibeshare-router # go build won't overwrite a fat (universal) binary
	@cd router && $(GO) build -o ../src/Sources/Resources/vibeshare-router .
	@echo "✅ src/Sources/Resources/vibeshare-router"

swift: router ## Build the Swift app (debug)
	@cd src && swift build
	@echo "✅ src/.build/debug/VibeShare"

build: swift ## Alias for swift (debug build)

app: ## Build and assemble VibeShare.app (release, signed, this machine's arch)
	@./create-app-bundle.sh

universal: ## Build a universal VibeShare.app (runs on Intel AND Apple Silicon)
	@UNIVERSAL=1 ./create-app-bundle.sh

install: app ## Build and install to /Applications
	@rm -rf "/Applications/VibeShare.app"
	@cp -R "VibeShare.app" /Applications/
	@echo "✅ Installed /Applications/VibeShare.app"

run: app ## Build and launch the app
	@open "VibeShare.app"

test: ## Test the Go router
	@cd router && $(GO) test ./...
	@echo "✅ go tests clean"

clean: ## Remove build artifacts and bundled router binary
	@rm -rf src/.build router/vibeshare-router src/Sources/Resources/vibeshare-router "VibeShare.app"
	@echo "✅ cleaned"
