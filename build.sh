#!/bin/bash
# Builds TrackpadTyping.app.
#
# A real bundle (rather than a bare executable) is required for two reasons:
# Accessibility permission is granted per bundle identifier, and LSUIElement is
# what keeps this out of the Dock and the app switcher.
set -euo pipefail
cd "$(dirname "$0")"

APP="TrackpadTyping.app"
BUNDLE_ID="com.local.trackpadtyping"

echo "==> Compiling"
swift build -c release

BIN=".build/release/TrackpadTyping"
[ -f "$BIN" ] || { echo "build produced no binary" >&2; exit 1; }

# Signing over a bundle whose binary is currently executing fails partway and
# leaves the bundle broken; stop the app first.
pkill -f "$APP/Contents/MacOS/TrackpadTyping" 2>/dev/null && sleep 1 || true

# This project directory is file-provider synced (Documents/iCloud). The sync
# daemon stamps extended attributes on files continuously, racing codesign
# between its detritus check and the seal — the source of every intermittent
# "resource fork/detritus" failure. Assemble and sign in private tmp space the
# daemon cannot see, then move the finished bundle into place.
STAGE="$(mktemp -d)/$APP"
trap 'rm -rf "$(dirname "$STAGE")"' EXIT

echo "==> Assembling $APP (staged)"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp -X "$BIN" "$STAGE/Contents/MacOS/TrackpadTyping"
# The lexicon ships inside the bundle. Without this, Bundle.module falls back
# to an absolute path into .build/ — which works on the build machine until a
# clean, then silently downgrades the app to the 1,300-word embedded list.
cp -RX .build/release/TrackpadTyping_TrackpadTyping.bundle "$STAGE/Contents/Resources/"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>TrackpadTyping</string>
    <key>CFBundleDisplayName</key>       <string>TrackpadTyping</string>
    <key>CFBundleExecutable</key>        <string>TrackpadTyping</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <!-- Menu-bar only: no Dock icon, no app-switcher entry. -->
    <key>LSUIElement</key>               <true/>
    <key>NSHumanReadableCopyright</key>  <string></string>
</dict>
</plist>
PLIST

# A real (if self-signed) identity beats ad hoc here: TCC pins an ad-hoc
# app's Accessibility grant to the exact binary hash, so every rebuild
# silently revokes it. With a certificate the grant pins to
# identifier+certificate and survives rebuilds.
# Launch Services and Finder decorate bundles with extended attributes that
# codesign refuses to seal; strip them or signing fails with "detritus".
xattr -cr "$STAGE"

# The signing key lives in a dedicated keychain with a stored password and
# its partition list opened to codesign, so signing never depends on an
# interactive keychain prompt — the failure mode that used to silently drop
# builds back to ad-hoc signatures and revoke Accessibility.
IDENTITY="TrackpadTyping Build"
KC="$HOME/Library/Keychains/trackpadtyping-build.keychain-db"
PASSFILE="$HOME/Library/Application Support/TrackpadTyping/build-keychain-pass"
if [ -f "$PASSFILE" ] && [ -f "$KC" ]; then
    security unlock-keychain -p "$(cat "$PASSFILE")" "$KC"
    echo "==> Signing ($IDENTITY)"
    codesign --force --deep --sign "$IDENTITY" --keychain "$KC" "$STAGE"
else
    echo "==> Signing (ad hoc — Accessibility will need re-granting after every rebuild)"
    codesign --force --deep --sign - "$STAGE"
fi

codesign --verify --deep "$STAGE" || { echo "signing is broken" >&2; exit 1; }

# Only now does the bundle enter synced space, signature already sealed.
rm -rf "$APP"
mv "$STAGE" "$APP"
trap - EXIT

echo
echo "Built $(pwd)/$APP"
# Only an ad-hoc signature pins the Accessibility grant to the exact binary;
# with the certificate the grant survives rebuilds and no warning is needed.
if codesign -dv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
    echo
    echo "!! Ad-hoc signature: macOS revokes Accessibility on every rebuild."
    echo "   Re-grant with:  tccutil reset Accessibility $BUNDLE_ID"
    echo "   then relaunch and approve the prompt."
fi
echo
echo "Launch with:  open $APP"
