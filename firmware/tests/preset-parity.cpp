#include "../MicMatrix/Renderer.h"
#include <stdio.h>
#include <string.h>

int main() {
  char line[MatrixProtocol::MaxLine + 2], expected[386];
  unsigned count = 0;
  while (fgets(line, sizeof(line), stdin)) {
    line[strcspn(line, "\n")] = 0;
    if (!fgets(expected, sizeof(expected), stdin)) return 2;
    expected[strcspn(expected, "\n")] = 0;
    MatrixProtocol::Command command;
    if (!MatrixProtocol::parse(line, command)) {
      fprintf(stderr, "Fixture command rejected at %u\n", count);
      return 2;
    }
    uint8_t output[64][3];
    MatrixProtocol::renderPreset(command, 0, output);
    char actual[385];
    for (unsigned i = 0; i < 64; ++i)
      snprintf(actual + i * 6, 7, "%02X%02X%02X", output[i][0], output[i][1], output[i][2]);
    if (strcmp(actual, expected)) {
      fprintf(stderr, "Preset parity mismatch at fixture %u\nExpected %s\nActual   %s\n",
              count, expected, actual);
      return 1;
    }
    ++count;
  }
  if (count != 7344) {
    fprintf(stderr, "Expected 7344 render fixtures, got %u\n", count);
    return 2;
  }
  printf("All %u Swift/firmware preset render fixtures match byte-for-byte.\n", count);
}
