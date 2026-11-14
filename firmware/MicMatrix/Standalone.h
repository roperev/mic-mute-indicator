#pragma once

#include "Renderer.h"
#include "Orientation.h"

namespace MatrixProtocol {
constexpr uint32_t StandaloneDelayMs = 10000;
constexpr uint32_t StandaloneLetterMs = 500;
constexpr uint32_t StandalonePauseMs = 3000;
constexpr uint8_t StandaloneBrightness = 51;
constexpr const char* StandaloneText = "MIC_MATRIX_v" MICMATRIX_FIRMWARE_VERSION;
constexpr size_t StandaloneLetterCount = sizeof("MIC_MATRIX_v" MICMATRIX_FIRMWARE_VERSION) - 1;

struct StandaloneState {
  PresetClock clock;
  bool computerSeen = false;

  void update(uint32_t now, bool usbHost) {
    clock.update(now);
    // A sleeping/disconnected computer must never turn a stale status into a demo.
    computerSeen = computerSeen || usbHost;
  }

  int letter(bool imuHealthy, bool hostLease) const {
    if (computerSeen || !imuHealthy || hostLease || clock.elapsedMs < StandaloneDelayMs) return -1;
    const uint64_t phase = (clock.elapsedMs - StandaloneDelayMs) %
      (StandaloneLetterCount * StandaloneLetterMs + StandalonePauseMs);
    return phase < StandaloneLetterCount * StandaloneLetterMs ? int(phase / StandaloneLetterMs) : -1;
  }
};

// Centered 5x7 glyphs for MIC_MATRIX; each displayed character has one color.
static const uint8_t StandaloneGlyphs[10][8] = {
  {0x44, 0x6c, 0x54, 0x44, 0x44, 0x44, 0x44, 0x00},
  {0x7c, 0x10, 0x10, 0x10, 0x10, 0x10, 0x7c, 0x00},
  {0x38, 0x44, 0x40, 0x40, 0x40, 0x44, 0x38, 0x00},
  {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7c, 0x00},
  {0x44, 0x6c, 0x54, 0x44, 0x44, 0x44, 0x44, 0x00},
  {0x38, 0x44, 0x44, 0x7c, 0x44, 0x44, 0x44, 0x00},
  {0x7c, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x00},
  {0x78, 0x44, 0x44, 0x78, 0x50, 0x48, 0x44, 0x00},
  {0x7c, 0x10, 0x10, 0x10, 0x10, 0x10, 0x7c, 0x00},
  {0x44, 0x44, 0x28, 0x10, 0x28, 0x44, 0x44, 0x00},
};
static const uint8_t StandaloneColors[10][3] = {
  {255, 255, 255}, {255, 255, 0}, {255, 128, 0}, {255, 255, 255},
  {255, 0, 0}, {180, 0, 255}, {0, 0, 255}, {0, 255, 0},
  {255, 255, 0}, {0, 255, 255},
};

inline const uint8_t* standaloneGlyph(size_t letter) {
  if (letter < 10) return StandaloneGlyphs[letter];
  if (letter == 10) return StandaloneGlyphs[3];
  static const uint8_t v[8] = {0, 0, 0x44, 0x44, 0x44, 0x28, 0x10, 0};
  if (letter == 11) return v;
  static const uint8_t dot[8] = {0, 0, 0, 0, 0, 0, 0x10, 0};
  static const uint8_t digits[10][8] = {
    {0x38,0x44,0x4c,0x54,0x64,0x44,0x38,0},
    {0x10,0x30,0x10,0x10,0x10,0x10,0x38,0},
    {0x38,0x44,0x04,0x08,0x10,0x20,0x7c,0},
    {0x78,0x04,0x04,0x38,0x04,0x04,0x78,0},
    {0x08,0x18,0x28,0x48,0x7c,0x08,0x08,0},
    {0x7c,0x40,0x40,0x78,0x04,0x04,0x78,0},
    {0x38,0x40,0x40,0x78,0x44,0x44,0x38,0},
    {0x7c,0x04,0x08,0x10,0x20,0x20,0x20,0},
    {0x38,0x44,0x44,0x38,0x44,0x44,0x38,0},
    {0x38,0x44,0x44,0x3c,0x04,0x04,0x38,0},
  };
  const char character = StandaloneText[letter];
  return character == '.' ? dot : digits[character - '0'];
}

inline void renderStandalone(int letter, uint8_t automaticRotation, uint8_t output[64][3]) {
  memset(output, 0, 64 * 3);
  if (letter < 0 || size_t(letter) >= StandaloneLetterCount) return;
  const uint8_t* glyph = standaloneGlyph(letter);
  const uint8_t* color = StandaloneColors[letter % 10];
  const uint8_t rotation = effectiveRotation(automaticRotation, 0, false);
  for (uint8_t y = 0; y < 8; ++y) {
    for (uint8_t x = 0; x < 8; ++x) {
      if ((glyph[y] & (0x80 >> x)) == 0) continue;
      const uint8_t index = pixelIndex(x, y, rotation);
      for (uint8_t channel = 0; channel < 3; ++channel) {
        output[index][channel] =
          uint16_t(MatrixArtwork::gamma[color[channel]]) * StandaloneBrightness / 255;
      }
    }
  }
}
}
