#include <assert.h>
#define main speaker_helper_main
#include "../../Native/speaker-helper.c"
#undef main

static void check(const float *vector, const char *expected) {
  FILE *out = tmpfile(); assert(out);
  fputc('[', out); write_embedding(out, vector, 2); fputc(']', out);
  rewind(out);
  char actual[64] = {0}; assert(fread(actual, 1, sizeof(actual)-1, out) > 0);
  assert(strcmp(actual, expected) == 0);
  fclose(out);
}

int main(void) {
  const float finite[] = {1, .5f}, nan[] = {1, NAN}, inf[] = {INFINITY, 1};
  check(finite, "[1.000000,0.500000]");
  check(NULL, "[]"); check(nan, "[]"); check(inf, "[]");
  puts("PASS: finite vectors serialized; NaN/Infinity/absent vectors preserve valid empty JSON");
  return 0;
}
