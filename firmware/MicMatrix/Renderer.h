#pragma once

#include <math.h>
#include "Protocol.h"

namespace MatrixProtocol {
constexpr uint32_t AnimationIntervalMs = 10;

struct PresetClock {
  uint64_t elapsedMs = 0;
  uint32_t lastAnimationClock = 0;

  void reset(uint32_t now) {
    elapsedMs = 0;
    lastAnimationClock = now;
  }
  void update(uint32_t now) {
    elapsedMs += uint32_t(now - lastAnimationClock);
    lastAnimationClock = now;
  }
};

inline bool presetAnimated(const Command& command) {
  return command.kind == Kind::Preset && command.icon &&
    (command.effect != 0 || strcmp(command.icon->name, "afk") == 0 ||
     strcmp(command.icon->name, "shrug") == 0);
}

inline double presetEffectGain(const Command& command, uint64_t elapsedMs) {
  if (command.effect == 0) return 1.0;
  const uint64_t phaseMs = uint64_t(command.effectPhaseMs) + elapsedMs;
  const double cycles = double(phaseMs) * command.rateMilliHz / 1000000.0;
  if (command.effect == 2) return fmod(cycles, 1.0) < 0.5 ? 1.0 : 0.0;
  const double wave = 0.5 - 0.5 * cos(6.2831853071795864769 * cycles);
  return 0.06 + 0.94 * wave * wave * wave;
}

inline void renderPreset(const Command& command, uint64_t elapsedMs, uint8_t output[64][3]) {
  memset(output, 0, 64 * 3);
  if (command.kind != Kind::Preset || !command.icon) return;
  const bool afk = strcmp(command.icon->name, "afk") == 0;
  const bool shrug = strcmp(command.icon->name, "shrug") == 0;
  const uint64_t iconMs = uint64_t(command.iconPhaseMs) + elapsedMs;
  const size_t afkFrame = (iconMs / 800) % 3;
  const int left = 8 - int((iconMs / 125) % (MatrixArtwork::ShrugWidth + 8));
  const double gain = presetEffectGain(command, elapsedMs);
  const uint8_t color[3] = {
    uint8_t(floor(command.red * gain + 0.5)),
    uint8_t(floor(command.green * gain + 0.5)),
    uint8_t(floor(command.blue * gain + 0.5))
  };
  uint8_t maximum = color[0] > color[1] ? color[0] : color[1];
  if (color[2] > maximum) maximum = color[2];
  const uint8_t black[3] = {};
  for (size_t i = 0; i < 64; ++i) {
    const uint8_t* source = command.icon->pixels[i];
    if (afk) source = MatrixArtwork::afk[afkFrame][i];
    if (shrug) {
      const int sourceX = int(i % 8) - left;
      source = sourceX >= 0 && size_t(sourceX) < MatrixArtwork::ShrugWidth
        ? MatrixArtwork::shrug[i / 8][sourceX] : black;
    }
    const bool lit = afk || shrug
      ? (source[0] != 0 || source[1] != 0 || source[2] != 0)
      : ((command.icon->mask >> (63 - i)) & 1) != 0;
    for (size_t channel = 0; channel < 3; ++channel) {
      uint8_t value;
      if (command.style == 0) {
        value = (uint16_t(source[channel]) * maximum + 127) / 255;
      } else if (command.style == 1) {
        value = uint16_t(source[channel]) * color[channel] / 255;
      } else {
        value = lit ? color[channel] : 0;
      }
      output[i][channel] =
        (uint32_t(MatrixArtwork::gamma[value]) * command.relative + 5000) / 10000;
    }
  }
}
}
