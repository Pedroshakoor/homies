#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app="$PWD/build/Piko.app"
/usr/bin/codesign --verify --strict "$app"
stage="$(mktemp -d /Applications/.Piko-install.XXXXXX)"
/usr/bin/ditto "$app" "$stage/Piko.app"
/usr/bin/codesign --verify --strict "$stage/Piko.app"
if [[ -e /Applications/Piko.app ]]; then
  mv /Applications/Piko.app "/private/tmp/Piko-previous-$(uuidgen).app"
fi
mv "$stage/Piko.app" /Applications/Piko.app
rmdir "$stage"
/usr/bin/codesign --verify --strict /Applications/Piko.app
print 'Installed: /Applications/Piko.app'
