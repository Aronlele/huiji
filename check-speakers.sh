#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/checks
COMMON=(Sources/MeetingTranscriber/Transcript.swift Sources/MeetingTranscriber/MeetingIntelligence.swift Sources/MeetingTranscriber/MeetingStore.swift Sources/MeetingTranscriber/MeetingAudioArchive.swift Sources/MeetingTranscriber/LocalSpeakerDiarizer.swift Sources/MeetingTranscriber/SpeakerClustering.swift)
swiftc -parse-as-library "${COMMON[@]}" Sources/MeetingTranscriber/SpeechSession.swift Tests/MeetingTranscriberTests/SpeakerIntegrationTests.swift -o .build/checks/SpeakerIntegrationTests
.build/checks/SpeakerIntegrationTests
swiftc -parse-as-library "${COMMON[@]}" Tests/MeetingTranscriberTests/SpeakerAccuracyTests.swift -o .build/checks/SpeakerAccuracyTests
.build/checks/SpeakerAccuracyTests
