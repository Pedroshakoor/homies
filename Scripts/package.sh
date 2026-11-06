#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app="$PWD/build/Homies.app"
[[ -x "$app/Contents/MacOS/Homies" ]] || { print 'Build Homies first with ./build.sh'; exit 1; }
/usr/bin/codesign --verify --strict "$app"
arch_name="$(/usr/bin/uname -m)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
stage="$PWD/build/dmg-root"
output="$PWD/build/Homies-${version}-macOS-${arch_name}.dmg"
rm -rf "$stage"
mkdir -p "$stage"
/usr/bin/ditto "$app" "$stage/Homies.app"
ln -s /Applications "$stage/Applications"
cat > "$stage/Read Me.txt" <<'TXT'
Homies
Your agents, one click away.

Welcome to your new sidekick for Mac.

1. Drag Homies.app into Applications.
2. Open Homies and click the Homies logo in your menu bar.
3. Choose an agent, connect your account, and select a project folder.
4. Start a conversation.

Works with your existing Codex, Claude Code, and Hermes installations
and accounts. Agent subscriptions are managed by their respective providers.

Made for macOS 14 or later on Apple Silicon.

TXT
/usr/bin/hdiutil create -volname Homies -srcfolder "$stage" -format UDZO -ov "$output"
/usr/bin/hdiutil verify "$output"
print "Package: $output"
