.PHONY: generate test lint format bundle release clean

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

clean:
	rm -rf .build PaperDrop.app PaperDrop.dmg Vendor PaperDrop.xcodeproj
