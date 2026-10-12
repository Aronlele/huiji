#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
MODELS="$PWD/Resources/SpeakerModels"
if [[ ! -f "$MODELS/embedding.onnx" || ! -f "$MODELS/vad.onnx" || ! -f "$MODELS/segmentation.onnx" || ! -f "$MODELS/libsherpa-onnx-c-api.dylib" ]]; then
  echo '请先运行 bash prepare-speaker-models.sh，准备本地说话人模型。' >&2
  exit 1
fi
swift design/make-icon.swift
iconutil -c icns .build/HuijiIcon.iconset -o Resources/HuijiIcon.icns
clang -O2 -mmacosx-version-min=26.0 Native/speaker-helper.c -I Native -L "$MODELS" -lsherpa-onnx-c-api -Wl,-rpath,@executable_path -o "$MODELS/speaker-helper"
swift build -c release
APP="$PWD/dist/会记.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/HuijiIcon.icns "$APP/Contents/Resources/HuijiIcon.icns"
mkdir -p "$APP/Contents/Resources/SpeakerModels"
cp "$MODELS"/* "$APP/Contents/Resources/SpeakerModels/"
for binary in "$APP/Contents/Resources/SpeakerModels/"*.dylib "$APP/Contents/Resources/SpeakerModels/speaker-helper"; do
  codesign --force --sign - "$binary"
done
cp .build/release/MeetingTranscriber "$APP/Contents/MacOS/MeetingTranscriber"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.huiji.meetingtranscriber</string>
<key>CFBundleName</key><string>会记</string>
<key>CFBundleDisplayName</key><string>会记</string>
<key>CFBundleExecutable</key><string>MeetingTranscriber</string>
<key>CFBundleIconFile</key><string>HuijiIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.3</string>
<key>CFBundleVersion</key><string>8</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSMicrophoneUsageDescription</key><string>会记需要麦克风声音，将你在会议中说的话转成中文文字。音频只在本机处理。</string>
<key>NSAudioCaptureUsageDescription</key><string>会记需要电脑播放的声音，将 Zoom 等会议中的语音转成中文文字。音频只在本机处理。</string>
<key>NSSpeechRecognitionUsageDescription</key><string>会记使用本机中文模型进行离线语音识别。</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier local.huiji.meetingtranscriber "$APP"
printf '已生成：%s\n' "$APP"
