NAME := Feather
SCHEME := Feather
PLATFORMS := iphoneos maccatalyst

TMP := $(TMPDIR)/$(NAME)
CERT_JSON_URL := https://backloop.dev/pack.json

.PHONY: all clean deps $(PLATFORMS)

all: $(PLATFORMS)

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


$(PLATFORMS): deps
	@if [ "$@" = "iphoneos" ]; then \
		DEST="generic/platform=iOS"; \
	else \
		DEST="generic/platform=macOS,variant=Mac Catalyst"; \
	fi; \
	rm -rf $(TMP)/$@/dst; \
	mkdir -p $(TMP)/$@/dst; \
	xcodebuild \
		-project Feather.xcodeproj \
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
	cp -R $(TMP)/$@/dst/Applications/*.app $(TMP)/$@/Payload/Feather.app
	chmod -R 0755 $(TMP)/$@/Payload/Feather.app
	codesign --force --sign - --timestamp=none $(TMP)/$@/Payload/Feather.app
	cp deps/* $(TMP)/$@/Payload/Feather.app/ || true

	mkdir -p packages

	@if [ "$@" = "iphoneos" ]; then \
		ditto -c -k --sequesterRsrc --keepParent $(TMP)/$@/Payload "packages/Feather.ipa"; \
	else \
		ditto -c -k --sequesterRsrc --keepParent $(TMP)/$@/Payload/Feather.app "packages/Feather_Catalyst.zip"; \
	fi
