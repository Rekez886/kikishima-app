#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/brand-assets Resources/Brand
swiftc -parse-as-library Sources/Kikishima/BrandIcons.swift tools/icon_assets/main.swift -o .build/brand-assets/generate-icons
.build/brand-assets/generate-icons .build/brand-assets/AppIcon.iconset
iconutil --convert icns .build/brand-assets/AppIcon.iconset --output Resources/Brand/AppIcon.icns
cp .build/brand-assets/AppIcon.iconset/icon_512x512@2x.png Resources/Brand/AppIcon-1024.png
