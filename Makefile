NAME := Aether
SCHEME := Aether
PLATFORMS := iphoneos maccatalyst

export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

TMP := $(TMPDIR)/$(NAME)
CERT_JSON_URL := https://backloop.dev/pack.json

.PHONY: all clean deps native openssl $(PLATFORMS)

all: $(PLATFORMS)

native:
	./IDeviceKitten/Native/build.sh

openssl:
	bash Zsign/build-openssl.sh

clean:
	rm -rf $(TMP)
	rm -rf packages
	rm -rf Payload

deps:
	rm -rf deps || true
	mkdir -p deps

	curl -fsSL "$(CERT_JSON_URL)" -o cert.json
	jq -r '.cert' cert.json > deps/server.crt
	jq -r '.key1, .key2' cert.json > deps/server.pem
	jq -r '.info.domains.commonName' cert.json > deps/commonName.txt


$(PLATFORMS): deps openssl
	@test -d IDeviceKitten/Native/IDevice.xcframework || $(MAKE) native
	@if [ "$@" = "iphoneos" ]; then \
		DEST="generic/platform=iOS"; \
	else \
		DEST="generic/platform=macOS,variant=Mac Catalyst"; \
	fi; \
	rm -rf $(TMP)/$@/dst; \
	mkdir -p $(TMP)/$@/dst; \
	xcodebuild \
		-project Aether.xcodeproj \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination "$$DEST" \
		-derivedDataPath $(TMP)/$@ \
		-skipPackagePluginValidation \
		DSTROOT=$(TMP)/$@/dst \
		CODE_SIGNING_ALLOWED=NO \
		ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO

	rm -rf $(TMP)/$@/Payload
	mkdir -p $(TMP)/$@/Payload
	cp -R $(TMP)/$@/dst/Applications/*.app $(TMP)/$@/Payload/Aether.app
	chmod -R 0755 $(TMP)/$@/Payload/Aether.app
	@if [ "$@" = "iphoneos" ]; then \
		TUNNEL="$(TMP)/$@/Payload/Aether.app/PlugIns/AetherTunnel.appex"; \
		if [ ! -d "$$TUNNEL" ]; then \
			echo "Missing embedded AetherTunnel.appex" >&2; \
			exit 1; \
		fi; \
		codesign --force --sign - --timestamp=none --entitlements AetherTunnel/AetherTunnel.entitlements "$$TUNNEL"; \
	fi
	codesign --force --sign - --timestamp=none $(TMP)/$@/Payload/Aether.app
	cp deps/* $(TMP)/$@/Payload/Aether.app/ || true

	mkdir -p packages

	@if [ "$@" = "iphoneos" ]; then \
		ditto -c -k --sequesterRsrc --keepParent $(TMP)/$@/Payload "packages/Aether.ipa"; \
	else \
		ditto -c -k --sequesterRsrc --keepParent $(TMP)/$@/Payload/Aether.app "packages/Aether_Catalyst.zip"; \
	fi
