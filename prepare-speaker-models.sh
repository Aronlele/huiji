#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
CACHE="$PWD/.build/speaker-downloads"
DEST="$PWD/Resources/SpeakerModels"
mkdir -p "$CACHE" "$DEST"
download() {
  local url="$1" name="$2" hash="$3"
  if [[ ! -f "$CACHE/$name" ]] || [[ "$(shasum -a 256 "$CACHE/$name" | cut -d ' ' -f 1)" != "$hash" ]]; then
    curl -fL --retry 2 --connect-timeout 15 --max-time 600 "$url" -o "$CACHE/$name"
  fi
  [[ "$(shasum -a 256 "$CACHE/$name" | cut -d ' ' -f 1)" == "$hash" ]] || { echo "校验失败：$name" >&2; exit 1; }
}
download 'https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts-lib.tar.bz2' runtime.tar.bz2 f3e0cbd86cc3f38dad30c97921b40e9a8bcc6f2c943777eb76ad77176993e417
download 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2' segmentation.tar.bz2 24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488
download 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2netv2_sv_zh-cn_16k-common.onnx' eres2netv2.onnx bf1a75b9930474cf3389ef415e6e5d38ca96fea4a3a00f7e301d080a58ee2239
download 'https://huggingface.co/csukuangfj/vad/resolve/af4fcfc9b8305246b1fe2ebcaf248975673166f1/silero_vad.onnx' silero_vad.onnx a35ebf52fd3ce5f1469b2a36158dba761bc47b973ea3382b3186ca15b1f5af28
tar -xjf "$CACHE/runtime.tar.bz2" -C "$CACHE"
tar -xjf "$CACHE/segmentation.tar.bz2" -C "$CACHE"
cp "$CACHE/sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts-lib/lib/libsherpa-onnx-c-api.dylib" "$DEST/"
cp "$CACHE/sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts-lib/lib/libonnxruntime.dylib" "$DEST/"
cp "$CACHE/sherpa-onnx-pyannote-segmentation-3-0/model.onnx" "$DEST/segmentation.onnx"
cp "$CACHE/eres2netv2.onnx" "$DEST/embedding.onnx"
cp "$CACHE/silero_vad.onnx" "$DEST/vad.onnx"
echo '本地说话人模型与运行库已准备好。'
