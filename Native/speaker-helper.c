#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "c-api.h"

static int compare_int(const void *a, const void *b) {
  int x = *(const int *)a, y = *(const int *)b;
  return (x > y) - (x < y);
}

static void write_embedding(FILE *out, const float *vector, int dimension) {
  if (!vector) return;
  for (int d = 0; d < dimension; ++d) if (!isfinite(vector[d])) return;
  for (int d = 0; d < dimension; ++d) fprintf(out, "%s%.6f", d ? "," : "", vector[d]);
}

// File-only inference. Segmentation supplies changes without pauses; VAD
// supplies pauses. Whole-fragment embeddings are clustered by the parent.
int main(int argc, char **argv) {
  if (argc != 6) return 2;
  int status = 4, written = 0;
  FILE *out = NULL;
  const SherpaOnnxWave *wave = SherpaOnnxReadWave(argv[3]);
  const SherpaOnnxOfflineSpeakerDiarization *sd = NULL;
  const SherpaOnnxOfflineSpeakerDiarizationResult *result = NULL;
  const SherpaOnnxOfflineSpeakerDiarizationSegment *turns = NULL;
  const SherpaOnnxVoiceActivityDetector *vad = NULL;
  const SherpaOnnxSpeakerEmbeddingExtractor *extractor = NULL;
  int *cuts = NULL, *vad_ranges = NULL;
  if (!wave || wave->sample_rate != 16000 || wave->num_samples <= 0) { status = 3; goto cleanup; }
  SherpaOnnxOfflineSpeakerDiarizationConfig config = {0};
  config.segmentation.pyannote.model = argv[1];
  config.segmentation.num_threads = 2; config.segmentation.provider = "cpu";
  config.embedding.model = argv[2];
  config.embedding.num_threads = 2; config.embedding.provider = "cpu";
  config.clustering.threshold = 0.7f;
  config.min_duration_on = 0.1f; config.min_duration_off = 0.1f;
  sd = SherpaOnnxCreateOfflineSpeakerDiarization(&config);
  if (!sd) goto cleanup;
  result = SherpaOnnxOfflineSpeakerDiarizationProcess(sd, wave->samples, wave->num_samples);
  if (!result) goto cleanup;
  int n = SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result);
  turns = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result);
  int max_vad = wave->num_samples / 3200 + 2;
  cuts = malloc(((size_t)n * 2 + (size_t)max_vad * 2 + 2) * sizeof(int));
  vad_ranges = malloc((size_t)max_vad * 2 * sizeof(int));
  if (!cuts || !vad_ranges) goto cleanup;
  SherpaOnnxVadModelConfig vc = {0};
  vc.silero_vad.model = argv[5]; vc.silero_vad.threshold = 0.5f;
  vc.silero_vad.min_silence_duration = 0.1f; vc.silero_vad.min_speech_duration = 0.2f;
  vc.silero_vad.window_size = 512; vc.silero_vad.max_speech_duration = 30;
  vc.sample_rate = 16000; vc.num_threads = 1; vc.provider = "cpu";
  vad = SherpaOnnxCreateVoiceActivityDetector(&vc, 60);
  extractor = SherpaOnnxCreateSpeakerEmbeddingExtractor(&config.embedding);
  if (!vad || !extractor) goto cleanup;
  int dimension = SherpaOnnxSpeakerEmbeddingExtractorDim(extractor);
  out = fopen(argv[4], "w");
  if (!out) { status = 6; goto cleanup; }
  int count = 0, vad_count = 0;
  cuts[count++] = 0; cuts[count++] = wave->num_samples;
  for (int k = 0; k < n; ++k) {
    int start = (int)(turns[k].start * 16000), end = (int)(turns[k].end * 16000);
    if (start > 0 && start < wave->num_samples) cuts[count++] = start;
    if (end > 0 && end < wave->num_samples) cuts[count++] = end;
  }
  // VAD adds pause boundaries, but is not a gate: quiet far-field interjections
  // found by segmentation must survive a VAD miss.
  for (int64_t i = 0; i < (int64_t)wave->num_samples + 512; i += 512) {
    if (i < wave->num_samples) {
      int count = wave->num_samples - (int)i;
      SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, wave->samples + i, count < 512 ? count : 512);
    } else { SherpaOnnxVoiceActivityDetectorFlush(vad); }
    while (!SherpaOnnxVoiceActivityDetectorEmpty(vad)) {
      const SherpaOnnxSpeechSegment *speech = SherpaOnnxVoiceActivityDetectorFront(vad);
      int start = speech->start, end = speech->start + speech->n;
      if (end > wave->num_samples) end = wave->num_samples;
      if (start >= 0 && end > start) {
        if (vad_count >= max_vad) { SherpaOnnxDestroySpeechSegment(speech); goto cleanup; }
        vad_ranges[vad_count * 2] = start; vad_ranges[vad_count * 2 + 1] = end; ++vad_count;
        cuts[count++] = start; cuts[count++] = end;
      }
      SherpaOnnxDestroySpeechSegment(speech);
      SherpaOnnxVoiceActivityDetectorPop(vad);
    }
  }
  qsort(cuts, count, sizeof(int), compare_int);
  fprintf(out, "[");
  int begin = 0;
  for (int k = 0; k < count; ++k) {
    int length = cuts[k] - begin;
    if (length <= 0) continue;
    double start = begin / 16000.0, end = cuts[k] / 16000.0;
    int overlap = 0, native_speaker = -1, active_speakers[3], active_count = 0, too_many = 0;
    double middle = (start + end) / 2;
    for (int a = 0; a < n; ++a) {
      if (turns[a].start <= middle && middle < turns[a].end) {
        if (native_speaker >= 0 && turns[a].speaker != native_speaker) overlap = 1;
        native_speaker = turns[a].speaker;
        int seen = 0;
        for (int b = 0; b < active_count; ++b) if (active_speakers[b] == native_speaker) seen = 1;
        if (!seen) {
          if (active_count < 3) active_speakers[active_count++] = native_speaker;
          else too_many = 1;
        }
      }
    }
    int active = native_speaker >= 0;
    int middle_sample = begin + length / 2;
    for (int a = 0; !active && a < vad_count; ++a)
      if (vad_ranges[a * 2] <= middle_sample && middle_sample < vad_ranges[a * 2 + 1]) active = 1;
    if (!active) { begin = cuts[k]; continue; }
    const SherpaOnnxOnlineStream *stream = NULL;
    const float *vector = NULL;
    // Keep short/mixed intervals in the timeline, but do not learn an
    // identity from them. Tiny feature matrices can produce NaN embeddings.
    if (!overlap && length >= 3200) {
      stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor);
      if (!stream) goto cleanup;
      SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, wave->samples + begin, length);
      SherpaOnnxOnlineStreamInputFinished(stream);
      if (SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream))
        vector = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream);
    }
    fprintf(out, "%s{\"start\":%.6f,\"end\":%.6f,\"overlap\":%s,\"nativeSpeaker\":%d,\"nativeSpeakers\":[",
        written++ ? "," : "", start, end, overlap ? "true" : "false", overlap ? -1 : native_speaker);
    if (!too_many) for (int a = 0; a < active_count; ++a) fprintf(out, "%s%d", a ? "," : "", active_speakers[a]);
    fprintf(out, "],\"vector\":[");
    write_embedding(out, vector, dimension);
    fprintf(out, "]}");
    if (vector) SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(vector);
    if (stream) SherpaOnnxDestroyOnlineStream(stream);
    begin = cuts[k];
  }
  fprintf(out, "]\n");
  status = ferror(out) ? 7 : 0;
cleanup:
  if (out && fclose(out) != 0) status = 7;
  free(cuts);
  free(vad_ranges);
  if (extractor) SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor);
  if (vad) SherpaOnnxDestroyVoiceActivityDetector(vad);
  if (turns) SherpaOnnxOfflineSpeakerDiarizationDestroySegment(turns);
  if (result) SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result);
  if (sd) SherpaOnnxDestroyOfflineSpeakerDiarization(sd);
  if (wave) SherpaOnnxFreeWave(wave);
  return status;
}
