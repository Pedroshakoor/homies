#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app="$PWD/build/Homies.app"
/usr/bin/codesign --verify --strict "$app"
stage="$(mktemp -d /Applications/.Homies-install.XXXXXX)"
/usr/bin/ditto "$app" "$stage/Homies.app"
/usr/bin/codesign --verify --strict "$stage/Homies.app"
if [[ -e /Applications/Homies.app ]]; then
  mv /Applications/Homies.app "/private/tmp/Homies-previous-$(uuidgen).app"
fi
mv "$stage/Homies.app" /Applications/Homies.app
rmdir "$stage"
/usr/bin/codesign --verify --strict /Applications/Homies.app
print 'Installed: /Applications/Homies.app'
