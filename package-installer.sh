#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/dist/会记.app"
if [[ ! -f "$APP/Contents/Info.plist" ]]; then
  echo '请先运行 bash build.sh。' >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo '应用版本号无效。' >&2
  exit 1
fi
mkdir -p .build "dist/releases/$VERSION"
STAGE=$(mktemp -d "$PWD/.build/installer.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/root"
ditto "$APP" "$STAGE/root/会记.app"
cat > "$STAGE/components.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><dict>
<key>RootRelativeBundlePath</key><string>会记.app</string>
<key>BundleIsRelocatable</key><false/>
<key>BundleIsVersionChecked</key><true/>
<key>BundleHasStrictIdentifier</key><true/>
<key>BundleOverwriteAction</key><string>upgrade</string>
</dict></array></plist>
PLIST
pkgbuild --root "$STAGE/root" --component-plist "$STAGE/components.plist" \
  --identifier local.huiji.meetingtranscriber.pkg --version "$VERSION" \
  --install-location /Applications --ownership recommended "$STAGE/huiji.pkg"
cat > "$STAGE/Distribution.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<installer-gui-script minSpecVersion="2">
  <title>会记 $VERSION</title>
  <welcome file="welcome.html" mime-type="text/html"/>
  <readme file="readme.html" mime-type="text/html"/>
  <conclusion file="conclusion.html" mime-type="text/html"/>
  <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <volume-check><allowed-os-versions><os-version min="26.0"/></allowed-os-versions></volume-check>
  <choices-outline><line choice="huiji"/></choices-outline>
  <choice id="huiji" title="会记" visible="false"><pkg-ref id="local.huiji.meetingtranscriber.pkg"/></choice>
  <pkg-ref id="local.huiji.meetingtranscriber.pkg" version="$VERSION" onConclusion="None">huiji.pkg</pkg-ref>
  <pkg-ref id="local.huiji.meetingtranscriber.pkg"><must-close><app id="local.huiji.meetingtranscriber"/></must-close></pkg-ref>
</installer-gui-script>
XML
OUTPUT="$PWD/dist/releases/$VERSION/Huiji-$VERSION-macOS-arm64.pkg"
productbuild --distribution "$STAGE/Distribution.xml" --package-path "$STAGE" \
  --resources packaging/installer --version "$VERSION" "$OUTPUT"
(cd "$(dirname "$OUTPUT")" && shasum -a 256 "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256")
printf '已生成安装向导：%s\n' "$OUTPUT"
