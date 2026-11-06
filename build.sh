#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/Homies.app/Contents/MacOS build/Homies.app/Contents/Resources build/module-cache
if [[ ! -f Resources/Homies.icns || Resources/Homies.jpg -nt Resources/Homies.icns || Scripts/MakeIcon.swift -nt Resources/Homies.icns ]]; then
  xcrun swiftc -O -warnings-as-errors -module-cache-path "$PWD/build/module-cache" Scripts/MakeIcon.swift -o build/make-icon
  build/make-icon Resources/Homies.jpg build/Homies.iconset Resources/AppAvatar.png
  /usr/bin/iconutil --convert icns build/Homies.iconset --output Resources/Homies.icns
fi
cp Resources/AppAvatar.png Frontend/public/AppAvatar.png
rm -f Frontend/public/Homies.gif
(cd Frontend && npm run build)
rm -rf build/Homies.app/Contents/Resources/Frontend
mkdir -p build/Homies.app/Contents/Resources/Frontend
cp -R Frontend/dist/. build/Homies.app/Contents/Resources/Frontend/
xcrun swiftc -swift-version 5 -warnings-as-errors -O -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$PWD/build/module-cache" -parse-as-library Sources/*.swift \
  -o build/Homies.app/Contents/MacOS/Homies
cp Resources/Info.plist build/Homies.app/Contents/Info.plist
cp Resources/Homies.icns build/Homies.app/Contents/Resources/Homies.icns
cp Resources/AppAvatar.png build/Homies.app/Contents/Resources/AppAvatar.png
cp Resources/HomiesMenu.png build/Homies.app/Contents/Resources/HomiesMenu.png
rm -rf build/Homies.app/Contents/Resources/MenuIcon
rm -f build/Homies.app/Contents/Resources/Homies.gif
xcrun swiftc -O -warnings-as-errors -module-cache-path "$PWD/build/module-cache" Scripts/CheckIcons.swift -o build/check-icons
build/check-icons Resources/AppAvatar.png
/usr/bin/codesign --force --sign "${HOMIES_SIGN_IDENTITY:--}" --options runtime --entitlements Resources/Homies.entitlements build/Homies.app
/usr/bin/codesign --verify --strict build/Homies.app
print "Built: $PWD/build/Homies.app"
