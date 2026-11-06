#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/Piko.app/Contents/MacOS build/Piko.app/Contents/Resources build/module-cache
if [[ ! -f Resources/AgentDrop.icns || Resources/AgentDrop.jpg -nt Resources/AgentDrop.icns || Scripts/MakeIcon.swift -nt Resources/AgentDrop.icns ]]; then
  xcrun swiftc -O -warnings-as-errors -module-cache-path "$PWD/build/module-cache" Scripts/MakeIcon.swift -o build/make-icon
  build/make-icon Resources/AgentDrop.jpg build/AgentDrop.iconset Resources/AppAvatar.png
  /usr/bin/iconutil --convert icns build/AgentDrop.iconset --output Resources/AgentDrop.icns
fi
cp Resources/AppAvatar.png Frontend/public/AppAvatar.png
rm -f Frontend/public/AgentDrop.gif
(cd Frontend && npm run build)
rm -rf build/Piko.app/Contents/Resources/Frontend
mkdir -p build/Piko.app/Contents/Resources/Frontend
cp -R Frontend/dist/. build/Piko.app/Contents/Resources/Frontend/
xcrun swiftc -swift-version 5 -warnings-as-errors -O -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$PWD/build/module-cache" -parse-as-library Sources/*.swift \
  -o build/Piko.app/Contents/MacOS/Piko
cp Resources/Info.plist build/Piko.app/Contents/Info.plist
cp Resources/AgentDrop.icns build/Piko.app/Contents/Resources/AgentDrop.icns
cp Resources/AppAvatar.png build/Piko.app/Contents/Resources/AppAvatar.png
rm -rf build/Piko.app/Contents/Resources/MenuIcon
rm -f build/Piko.app/Contents/Resources/AgentDrop.gif
xcrun swiftc -O -warnings-as-errors -module-cache-path "$PWD/build/module-cache" Scripts/CheckIcons.swift -o build/check-icons
build/check-icons Resources/AppAvatar.png
/usr/bin/codesign --force --sign "${AGENTDROP_SIGN_IDENTITY:--}" --options runtime --entitlements Resources/AgentDrop.entitlements build/Piko.app
/usr/bin/codesign --verify --strict build/Piko.app
print "Built: $PWD/build/Piko.app"
