#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/checks
clang -O2 Tests/MeetingTranscriberTests/NativeEmbeddingTests.c -I Native -L Resources/SpeakerModels -lsherpa-onnx-c-api -Wl,-rpath,"$PWD/Resources/SpeakerModels" -o .build/checks/NativeEmbeddingTests
.build/checks/NativeEmbeddingTests
swiftc Sources/MeetingTranscriber/Transcript.swift Tests/MeetingTranscriberTests/TranscriptTests.swift -o .build/checks/TranscriptTests
.build/checks/TranscriptTests
swiftc Sources/MeetingTranscriber/Transcript.swift Sources/MeetingTranscriber/MeetingStore.swift Tests/MeetingTranscriberTests/MeetingStoreTests.swift -o .build/checks/MeetingStoreTests
.build/checks/MeetingStoreTests
swiftc -parse-as-library Sources/MeetingTranscriber/Transcript.swift Sources/MeetingTranscriber/MeetingStore.swift Sources/MeetingTranscriber/MeetingAudioArchive.swift Sources/MeetingTranscriber/LocalSpeakerDiarizer.swift Sources/MeetingTranscriber/SpeakerClustering.swift Sources/MeetingTranscriber/LocalMeetingAI.swift Sources/MeetingTranscriber/MeetingModel.swift Tests/MeetingTranscriberTests/MicrophoneSwitchTests.swift -o .build/checks/MicrophoneSwitchTests
.build/checks/MicrophoneSwitchTests
swiftc Sources/MeetingTranscriber/Transcript.swift Sources/MeetingTranscriber/MeetingStore.swift Tests/MeetingTranscriberTests/SpeakerTests.swift -o .build/checks/SpeakerTests
.build/checks/SpeakerTests
swiftc Sources/MeetingTranscriber/Transcript.swift Sources/MeetingTranscriber/SpeakerClustering.swift Tests/MeetingTranscriberTests/SpeakerClusteringTests.swift -o .build/checks/SpeakerClusteringTests
.build/checks/SpeakerClusteringTests
