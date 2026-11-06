#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app="$PWD/build/Piko.app"
[[ -x "$app/Contents/MacOS/Piko" ]] || { print 'Build Piko first with ./build.sh'; exit 1; }
/usr/bin/codesign --verify --strict "$app"
arch_name="$(/usr/bin/uname -m)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
stage="$PWD/build/dmg-root"
output="$PWD/build/Piko-${version}-macOS-${arch_name}.dmg"
rm -rf "$stage"
mkdir -p "$stage"
/usr/bin/ditto "$app" "$stage/Piko.app"
ln -s /Applications "$stage/Applications"
cat > "$stage/Read Me.txt" <<'TXT'
Piko
Your agents, one click away.

Welcome to your new sidekick for Mac.

1. Drag Piko.app into Applications.
2. Open Piko and click the yellow gecko in your menu bar.
3. Choose an agent, connect your account, and select a project folder.
4. Start a conversation.

Works with your existing Codex, Claude Code, and Hermes installations
and accounts. Agent subscriptions are managed by their respective providers.

Made for macOS 14 or later on Apple Silicon.

TXT
/usr/bin/hdiutil create -volname Piko -srcfolder "$stage" -format UDZO -ov "$output"
/usr/bin/hdiutil verify "$output"
print "Package: $output"
