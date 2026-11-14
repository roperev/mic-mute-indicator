#include "../MicMatrix/Standalone.h"
#include <assert.h>
#include <stdio.h>

using namespace MatrixProtocol;

int main() {
  StandaloneState state;
  state.update(9999, false);
  assert(state.letter(true, false) == -1);
  const uint32_t lettersMs = StandaloneLetterCount * StandaloneLetterMs;
  const uint32_t cycleMs = lettersMs + StandalonePauseMs;
  assert(strcmp(StandaloneText, "MIC_MATRIX_v" MICMATRIX_FIRMWARE_VERSION) == 0);
  assert(strlen(StandaloneText) == StandaloneLetterCount);
  for (uint32_t cycle = 0; cycle < 3; ++cycle) {
    for (size_t letter = 0; letter < StandaloneLetterCount; ++letter) {
      const uint32_t start = 10000 + cycle * cycleMs + letter * 500;
      state.update(start, false);
      assert(state.letter(true, false) == int(letter));
      assert(state.letter(false, false) == -1);
      assert(state.letter(true, true) == -1);
      state.update(start + 499, false);
      assert(state.letter(true, false) == int(letter));
      for (uint8_t rotation = 0; rotation < 4; ++rotation) {
        uint8_t output[64][3];
        renderStandalone(letter, rotation, output);
        unsigned lit = 0;
        for (uint8_t y = 0; y < 8; ++y) {
          for (uint8_t x = 0; x < 8; ++x) {
            const uint8_t index = pixelIndex(x, y, effectiveRotation(rotation, 0, false));
            const bool on = (standaloneGlyph(letter)[y] & (0x80 >> x)) != 0;
            for (uint8_t c = 0; c < 3; ++c) {
              const uint8_t expected = on ?
                uint16_t(MatrixArtwork::gamma[StandaloneColors[letter % 10][c]]) * 51 / 255 : 0;
              assert(output[index][c] == expected && output[index][c] <= 51);
            }
            lit += on;
          }
        }
        assert(lit > 0 && lit < 32);
      }
    }
    state.update(10000 + lettersMs + cycle * cycleMs, false);
    assert(state.letter(true, false) == -1);
    state.update(10000 + (cycle + 1) * cycleMs - 1, false);
    assert(state.letter(true, false) == -1);
  }
  state.update(10000 + 3 * cycleMs, true);
  assert(state.letter(true, false) == -1);
  state.update(20000 + 3 * cycleMs, false);
  assert(state.letter(true, false) == -1); // Suspended PC never becomes a power-only demo.
  StandaloneState hostAtBoot;
  hostAtBoot.update(1, true);
  hostAtBoot.update(12000, false);
  assert(hostAtBoot.letter(true, false) == -1);
  StandaloneState rollover;
  rollover.update(UINT32_MAX - 1, false);
  const uint64_t before = rollover.clock.elapsedMs;
  rollover.update(2, false);
  assert(rollover.clock.elapsedMs == before + 4);
  const uint64_t phase = (rollover.clock.elapsedMs - 10000) % cycleMs;
  assert(rollover.letter(true, false) == (phase < lettersMs ? int(phase / 500) : -1));
  uint8_t blank[64][3];
  renderStandalone(-1, 0, blank);
  for (const auto& pixel : blank) for (auto channel : pixel) assert(channel == 0);
  assert(MaxBrightness == 25 && scaled(255, 255) == 25); // Host-controlled cap is unchanged.
  puts("Standalone demo tests passed: exact letters/timing/pause, rotation, 20% ceiling, host latch, IMU safety and rollover.");
}
