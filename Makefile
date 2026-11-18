.PHONY: generate test lint format bundle release appstore clean

# (Re)generate PaperDrop.xcodeproj from project.yml.
generate:
	xcodegen generate

test: generate
	xcodebuild -project PaperDrop.xcodeproj -scheme PaperDrop \
		-destination 'platform=macOS' test

lint:
	swift format lint --strict --recursive Sources Tests Package.swift

format:
	swift format --in-place --recursive Sources Tests Package.swift

bundle:
	./bundle.sh

release:
	./release.sh

# Mac App Store build: archive the sandboxed target and export a signed
# .pkg for upload (Transporter or `xcrun altool`). Xcode creates the App ID,
# certificates and profile on first run if the account allows it.
appstore: generate
	xcodebuild -project PaperDrop.xcodeproj -scheme PaperDropAppStore \
		-configuration Release -archivePath build/PaperDropAppStore.xcarchive \
		-allowProvisioningUpdates archive
	xcodebuild -exportArchive -archivePath build/PaperDropAppStore.xcarchive \
		-exportOptionsPlist AppStore/ExportOptions.plist \
		-exportPath build/AppStore -allowProvisioningUpdates

clean:
	rm -rf .build build PaperDrop.app PaperDrop.dmg Vendor PaperDrop.xcodeproj
