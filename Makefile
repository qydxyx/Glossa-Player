ENGINE := target/debug/glossa-engine
ENGINE_REL := target/release/glossa-engine
APP_DIR := build/Build/Products/Debug/Glossa Player.app
APP_REL := build/Build/Products/Release/Glossa Player.app
DERIVED := build
DIST := dist
VERSION := 1.0.0

.PHONY: engine app run test fixtures sidecar dist

engine:
	cargo build -p glossa-engine

test:
	cargo test --workspace

app: engine
	xcodegen generate
	rm -rf "$(APP_DIR)/Contents/Helpers"
	xcodebuild -project Glossa.xcodeproj -scheme Glossa -configuration Debug \
		-derivedDataPath $(DERIVED) \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES
	mkdir -p "$(APP_DIR)/Contents/Helpers"
	cp $(ENGINE) "$(APP_DIR)/Contents/Helpers/glossa-engine"
	cp sidecar/qwen3-asr/qwen3_asr_sidecar.py "$(APP_DIR)/Contents/Helpers/qwen3_asr_sidecar.py"

run: app
	open "$(APP_DIR)"

fixtures:
	bash scripts/make-fixture.sh

sidecar:
	@PY=$$(command -v python3.13 || command -v python3.12 || command -v python3.11 || command -v python3); \
	echo "sidecar python: $$PY"; \
	"$$PY" -m venv sidecar/qwen3-asr/.venv
	sidecar/qwen3-asr/.venv/bin/pip install -U pip
	sidecar/qwen3-asr/.venv/bin/pip install -r sidecar/qwen3-asr/requirements.txt
	mkdir -p "$(HOME)/Library/Application Support/Glossa/qwen3-asr"
	ln -sfn "$(CURDIR)/sidecar/qwen3-asr/.venv" "$(HOME)/Library/Application Support/Glossa/qwen3-asr/.venv"
	cp sidecar/qwen3-asr/qwen3_asr_sidecar.py "$(HOME)/Library/Application Support/Glossa/qwen3_asr_sidecar.py"

dist:
	cargo build --release -p glossa-engine
	xcodegen generate
	rm -rf "$(APP_REL)/Contents/Helpers"
	xcodebuild -project Glossa.xcodeproj -scheme Glossa -configuration Release \
		-derivedDataPath $(DERIVED) \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES
	mkdir -p "$(APP_REL)/Contents/Helpers"
	cp $(ENGINE_REL) "$(APP_REL)/Contents/Helpers/glossa-engine"
	cp sidecar/qwen3-asr/qwen3_asr_sidecar.py "$(APP_REL)/Contents/Helpers/qwen3_asr_sidecar.py"
	mkdir -p $(DIST)
	rm -rf $(DIST)/dmgroot
	mkdir -p $(DIST)/dmgroot
	ditto "$(APP_REL)" "$(DIST)/dmgroot/Glossa Player.app"
	ln -s /Applications "$(DIST)/dmgroot/Applications"
	rm -f "$(DIST)/Glossa-Player-$(VERSION).dmg" "$(DIST)/Glossa-Player-$(VERSION).zip"
	hdiutil create -volname "Glossa Player" -srcfolder "$(DIST)/dmgroot" \
		-ov -format UDZO "$(DIST)/Glossa-Player-$(VERSION).dmg"
	ditto -c -k --keepParent "$(APP_REL)" "$(DIST)/Glossa-Player-$(VERSION).zip"
	ls -lh "$(DIST)/Glossa-Player-$(VERSION).dmg" "$(DIST)/Glossa-Player-$(VERSION).zip"
