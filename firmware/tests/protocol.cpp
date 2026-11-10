#include "../MicMatrix/Protocol.h"
#include "../MicMatrix/Orientation.h"
#include "../MicMatrix/Renderer.h"
#include <assert.h>
#include <stdio.h>

using namespace MatrixProtocol;

bool accepts(const char* text, Command& result) {
  char line[MaxLine + 1];
  assert(strlen(text) <= MaxLine);
  strcpy(line, text);
  return parse(line, result);
}

void rejectsAtomically(const char* text, Command& result) {
  unsigned char before[sizeof(Command)];
  memcpy(before, &result, sizeof(result));
  assert(!accepts(text, result));
  assert(memcmp(before, &result, sizeof(result)) == 0);
}

void presetLine(char* line, const char* const arguments[11]) {
  const int count = snprintf(line, MaxLine + 1,
    "PRESET %s %s %s %s %s %s %s %s %s %s %s",
    arguments[0], arguments[1], arguments[2], arguments[3], arguments[4],
    arguments[5], arguments[6], arguments[7], arguments[8], arguments[9], arguments[10]);
  assert(count > 0 && size_t(count) <= MaxLine);
}

void testPresets() {
  assert(MatrixArtwork::IconCount > 0);
  assert(findIcon(nullptr) == nullptr && findIcon("not-an-icon") == nullptr);
  for (size_t i = 0; i < MatrixArtwork::IconCount; ++i) {
    assert(findIcon(MatrixArtwork::icons[i].name) == &MatrixArtwork::icons[i]);
  }
  const char* arguments[11] = {
    "4294967295", MatrixArtwork::icons[0].name, "2", "a1B2c3", "255", "7",
    "10000", "2", "10000", "4294967295", "4294967295"
  };
  char line[MaxLine + 1];
  Command command;
  presetLine(line, arguments);
  assert(accepts(line, command) && command.kind == Kind::Preset);
  assert(command.sequence == UINT32_MAX && command.icon == &MatrixArtwork::icons[0]);
  assert(command.style == 2 && command.red == 0xa1 && command.green == 0xb2 &&
         command.blue == 0xc3 && command.brightness == MaxBrightness);
  assert(command.rotation == 3 && command.mirrored && command.relative == 10000);
  assert(command.effect == 2 && command.rateMilliHz == 10000);
  assert(command.effectPhaseMs == UINT32_MAX && command.iconPhaseMs == UINT32_MAX);
  struct InvalidArgument { size_t index; const char* value; };
  const InvalidArgument invalid[] = {
    {0, "-1"}, {0, "+1"}, {0, "4294967296"}, {0, "1x"},
    {1, "not-an-icon"}, {1, "AFK"}, {2, "-1"}, {2, "3"}, {2, "1.0"},
    {3, "00000"}, {3, "0000000"}, {3, "#00000"}, {3, "G00000"},
    {4, "-1"}, {4, "256"}, {4, "nan"}, {5, "-1"}, {5, "8"},
    {6, "-1"}, {6, "10001"}, {6, "0.5"}, {7, "-1"}, {7, "3"},
    {8, "0"}, {8, "99"}, {8, "10001"}, {8, "-100"}, {8, "100.0"},
    {9, "-1"}, {9, "4294967296"}, {10, "-1"}, {10, "4294967296"}
  };
  for (const InvalidArgument& item : invalid) {
    const char* saved = arguments[item.index];
    arguments[item.index] = item.value;
    presetLine(line, arguments);
    rejectsAtomically(line, command);
    arguments[item.index] = saved;
  }
  presetLine(line, arguments);
  strcat(line, " extra");
  rejectsAtomically(line, command);
  presetLine(line, arguments);
  *strrchr(line, ' ') = '\0';
  rejectsAtomically(line, command);
  rejectsAtomically("PRESET", command);
  rejectsAtomically("KEEP", command);
  rejectsAtomically("KEEP -1", command);
  rejectsAtomically("KEEP 4294967296", command);
  rejectsAtomically("KEEP 1 extra", command);
  assert(accepts("KEEP 4294967295", command));
  assert(command.kind == Kind::Keep && command.sequence == UINT32_MAX && !command.icon);
  const char* minima[11] = {
    "0", MatrixArtwork::icons[0].name, "0", "000000", "0", "0",
    "0", "0", "100", "0", "0"
  };
  presetLine(line, minima);
  assert(accepts(line, command));
  assert(command.sequence == 0 && command.style == 0 && command.red == 0 &&
         command.green == 0 && command.blue == 0 && command.brightness == 0 &&
         command.rotation == 0 && !command.mirrored && command.relative == 0 &&
         command.effect == 0 && command.rateMilliHz == 100 &&
         command.effectPhaseMs == 0 && command.iconPhaseMs == 0);
  for (unsigned brightness = 0; brightness < 256; ++brightness) {
    char value[4];
    snprintf(value, sizeof(value), "%u", brightness);
    minima[4] = value;
    presetLine(line, minima);
    assert(accepts(line, command) && command.brightness == limitedBrightness(brightness));
  }
  minima[4] = "25";
  for (uint8_t flags = 0; flags < 8; ++flags) {
    char value[2] = {char('0' + flags), '\0'};
    minima[5] = value;
    for (uint8_t style = 0; style < 3; ++style) {
      char styleValue[2] = {char('0' + style), '\0'};
      minima[2] = styleValue;
      minima[7] = styleValue;
      presetLine(line, minima);
      assert(accepts(line, command));
      assert(command.rotation == (flags & 3) && command.mirrored == bool(flags & 4));
      assert(command.style == style && command.effect == style);
    }
  }
  char oversized[MaxLine + 2];
  memset(oversized, 'X', sizeof(oversized));
  oversized[MaxLine + 1] = '\0';
  unsigned char before[sizeof(command)];
  memcpy(before, &command, sizeof(command));
  assert(!parse(oversized, command) && memcmp(before, &command, sizeof(command)) == 0);
  assert(!parse(nullptr, command));
}

void testLease() {
  DisplayLease lease;
  assert(!lease.valid(0) && !lease.keep(0));
  lease.start(100);
  assert(lease.valid(3099) && !lease.valid(3100));
  assert(!lease.keep(3100) && !lease.active);
  assert(!lease.keep(3101));
  lease.start(100);
  assert(lease.keep(3099) && lease.renewedAt == 3099);
  assert(lease.valid(6098) && !lease.valid(6099));
  lease.stop();
  assert(!lease.active && !lease.keep(3100));
  lease.start(UINT32_MAX - 1000);
  assert(lease.valid(1998) && !lease.valid(1999));
  assert(lease.keep(1000) && lease.renewedAt == 1000);
  // Rendering, telemetry and parsing have no access to the display lease.
  Command command;
  const char* messages[] = {"HELLO", "STATUS", "ORIENTATION", "KEEP 1", "OFF 2"};
  for (const char* message : messages) {
    assert(accepts(message, command));
    assert(lease.renewedAt == 1000);
  }
  rejectsAtomically("invalid", command);
  command.kind = Kind::Preset;
  command.icon = &MatrixArtwork::icons[0];
  command.effect = 1;
  uint8_t output[64][3];
  for (uint32_t elapsed = 0; elapsed <= TimeoutMs; elapsed += AnimationIntervalMs) {
    renderPreset(command, elapsed, output);
    assert(lease.renewedAt == 1000);
  }
  assert(lease.renewedAt == 1000 && !lease.keep(4000));
}

uint8_t expectedRelative(uint8_t value, uint16_t relative) {
  return (uint32_t(MatrixArtwork::gamma[value]) * relative + 5000) / 10000;
}

void assertLongRunningRender(uint64_t elapsedMs) {
  const char* names[] = {"afk", "shrug"};
  for (const char* name : names) {
    Command command;
    command.kind = Kind::Preset;
    command.icon = findIcon(name);
    assert(command.icon);
    command.red = 127;
    command.green = 201;
    command.blue = 253;
    command.relative = 6173;
    command.effectPhaseMs = command.iconPhaseMs = UINT32_MAX;
    const uint64_t iconPeriod = strcmp(name, "afk") == 0
      ? 2400 : (MatrixArtwork::ShrugWidth + 8) * 125;
    uint64_t a = iconPeriod, b = 1000;
    while (b) {
      const uint64_t remainder = a % b;
      a = b;
      b = remainder;
    }
    const uint64_t period = iconPeriod / a * 1000;
    for (uint8_t effect = 0; effect < 3; ++effect) {
      command.effect = effect;
      assert(fabs(presetEffectGain(command, elapsedMs) -
                  presetEffectGain(command, elapsedMs % period)) < 1e-7);
      for (uint8_t style = 0; style < 3; ++style) {
        command.style = style;
        uint8_t actual[64][3], expected[64][3];
        renderPreset(command, elapsedMs, actual);
        renderPreset(command, elapsedMs % period, expected);
        assert(memcmp(actual, expected, sizeof(actual)) == 0);
      }
    }
  }
}

void testPresetClock() {
  PresetClock clock;
  clock.reset(UINT32_MAX - 15);
  clock.update(UINT32_MAX - 5);
  assert(clock.elapsedMs == 10);
  clock.update(4);
  assert(clock.elapsedMs == 20 && clock.lastAnimationClock == 4);
  clock.update(4);
  assert(clock.elapsedMs == 20);

  clock.reset(0);
  DisplayLease lease;
  lease.start(0);
  uint64_t elapsed = 0;
  const uint64_t beforeWrap = uint64_t(UINT32_MAX) - 1;
  while (elapsed < beforeWrap) {
    const uint32_t step = beforeWrap - elapsed < 1000 ? beforeWrap - elapsed : 1000;
    elapsed += step;
    clock.update(uint32_t(elapsed));
    assert(clock.elapsedMs == elapsed);
    assert(lease.keep(uint32_t(elapsed)));
    assert(clock.elapsedMs == elapsed);
  }
  assertLongRunningRender(clock.elapsedMs);
  const uint32_t steps[] = {1, 1, 1, 10, 125, 800, 1000, 1000};
  for (uint32_t step : steps) {
    elapsed += step;
    clock.update(uint32_t(elapsed));
    assert(clock.elapsedMs == elapsed);
    assert(lease.keep(uint32_t(elapsed)));
    assert(clock.elapsedMs == elapsed);
    assertLongRunningRender(clock.elapsedMs);
  }
  assert(clock.elapsedMs > UINT32_MAX);
  // Neither watchdog expiry nor OFF resets the independent animation clock.
  elapsed += TimeoutMs;
  clock.update(uint32_t(elapsed));
  assert(!lease.keep(uint32_t(elapsed)) && clock.elapsedMs == elapsed);
  lease.stop();
  assert(clock.elapsedMs == elapsed);
  clock.reset(uint32_t(elapsed));
  assert(clock.elapsedMs == 0 && clock.lastAnimationClock == uint32_t(elapsed));
}

void testRenderer() {
  assert(AnimationIntervalMs == 10);
  MatrixArtwork::Icon icon = {};
  icon.name = "test";
  icon.mask = UINT64_C(0x8000000000000001);
  icon.pixels[1][0] = 123;
  icon.pixels[1][1] = 231;
  icon.pixels[1][2] = 17;
  icon.pixels[63][0] = 255;
  icon.pixels[63][1] = 128;
  icon.pixels[63][2] = 64;
  Command command;
  command.kind = Kind::Preset;
  command.icon = &icon;
  command.red = 129;
  command.green = 67;
  command.blue = 201;
  const uint8_t color[3] = {129, 67, 201};
  uint8_t output[64][3];
  const uint16_t relatives[] = {0, 1, 3333, 5000, 9999, 10000};
  for (uint8_t style = 0; style < 3; ++style) {
    command.style = style;
    assert(!presetAnimated(command));
    for (uint16_t relative : relatives) {
      command.relative = relative;
      renderPreset(command, 12345, output);
      for (size_t i = 0; i < 64; ++i) {
        for (size_t channel = 0; channel < 3; ++channel) {
          uint8_t value;
          if (style == 0) value = (uint16_t(icon.pixels[i][channel]) * 201 + 127) / 255;
          else if (style == 1) value = uint16_t(icon.pixels[i][channel]) * color[channel] / 255;
          else value = ((icon.mask >> (63 - i)) & 1) ? color[channel] : 0;
          assert(output[i][channel] == expectedRelative(value, relative));
        }
      }
    }
  }
  command.relative = 10000;
  command.style = 2;
  command.effect = 1;
  command.rateMilliHz = 1000;
  assert(presetAnimated(command));
  assert(fabs(presetEffectGain(command, 0) - 0.06) < 1e-12);
  assert(fabs(presetEffectGain(command, 250) - 0.1775) < 1e-12);
  assert(fabs(presetEffectGain(command, 500) - 1.0) < 1e-12);
  renderPreset(command, 0, output);
  assert(output[0][0] == MatrixArtwork::gamma[8] &&
         output[0][1] == MatrixArtwork::gamma[4] &&
         output[0][2] == MatrixArtwork::gamma[12]);
  renderPreset(command, 500, output);
  for (size_t c = 0; c < 3; ++c) assert(output[0][c] == MatrixArtwork::gamma[color[c]]);
  command.effectPhaseMs = 250;
  renderPreset(command, 250, output);
  for (size_t c = 0; c < 3; ++c) assert(output[0][c] == MatrixArtwork::gamma[color[c]]);
  const uint32_t pulseTimes[] = {0, 17, 127, 250, 499, 777, 999};
  command.effectPhaseMs = 0;
  for (uint32_t time : pulseTimes) {
    const double wave = 0.5 - 0.5 * cos(6.2831853071795864769 * double(time) / 1000);
    const double gain = 0.06 + 0.94 * wave * wave * wave;
    uint8_t effectColor[3];
    uint8_t maximum = 0;
    for (size_t c = 0; c < 3; ++c) {
      effectColor[c] = uint8_t(floor(color[c] * gain + 0.5));
      if (effectColor[c] > maximum) maximum = effectColor[c];
    }
    for (uint8_t style = 0; style < 2; ++style) {
      command.style = style;
      command.relative = 6173;
      renderPreset(command, time, output);
      for (size_t i = 0; i < 64; ++i) {
        for (size_t c = 0; c < 3; ++c) {
          const uint8_t value = style == 0
            ? (uint16_t(icon.pixels[i][c]) * maximum + 127) / 255
            : uint16_t(icon.pixels[i][c]) * effectColor[c] / 255;
          assert(output[i][c] == expectedRelative(value, 6173));
        }
      }
    }
  }
  command.style = 2;
  command.relative = 10000;
  command.effect = 2;
  command.effectPhaseMs = 0;
  const uint32_t flashTimes[] = {0, 499, 500, 999, 1000};
  const bool flashOn[] = {true, true, false, false, true};
  for (size_t i = 0; i < 5; ++i) {
    renderPreset(command, flashTimes[i], output);
    assert(output[0][2] == MatrixArtwork::gamma[flashOn[i] ? color[2] : 0]);
  }
  command.effectPhaseMs = UINT32_MAX;
  assert(presetEffectGain(command, 205) == 0.0);
  assert(presetEffectGain(command, 705) == 1.0);
  command.effect = 1;
  const double cycles = double(uint64_t(UINT32_MAX) + 205) / 1000;
  const double wave = 0.5 - 0.5 * cos(6.2831853071795864769 * cycles);
  assert(fabs(presetEffectGain(command, 205) - (0.06 + 0.94 * wave * wave * wave)) < 1e-12);
  command.effect = 0;
  command.effectPhaseMs = 0;
  command.red = command.green = command.blue = 255;
  const char* animatedNames[] = {"afk", "shrug"};
  for (const char* name : animatedNames) {
    command.icon = findIcon(name);
    assert(command.icon && presetAnimated(command));
    const uint32_t times[] = {0, 124, 125, 799, 800, 1599, 1600, 2399, 2400, 5749, 5750};
    const uint32_t phases[] = {0, UINT32_MAX};
    for (uint32_t phase : phases) {
      command.iconPhaseMs = phase;
      for (uint32_t time : times) {
        const uint64_t phaseTime = uint64_t(phase) + time;
        const int left = 8 - int((phaseTime / 125) % (MatrixArtwork::ShrugWidth + 8));
        for (uint8_t style = 0; style < 3; ++style) {
          command.style = style;
          renderPreset(command, time, output);
          for (size_t i = 0; i < 64; ++i) {
            uint8_t source[3] = {};
            if (strcmp(name, "afk") == 0) {
              memcpy(source, MatrixArtwork::afk[(phaseTime / 800) % 3][i], 3);
            } else {
              const int sourceX = int(i % 8) - left;
              if (sourceX >= 0 && size_t(sourceX) < MatrixArtwork::ShrugWidth) {
                memcpy(source, MatrixArtwork::shrug[i / 8][sourceX], 3);
              }
            }
            const bool lit = source[0] || source[1] || source[2];
            for (size_t c = 0; c < 3; ++c) {
              const uint8_t value = style == 2 ? (lit ? 255 : 0) : source[c];
              assert(output[i][c] == MatrixArtwork::gamma[value]);
            }
          }
        }
      }
    }
  }
  command.kind = Kind::Off;
  assert(!presetAnimated(command));
  memset(output, 255, sizeof(output));
  renderPreset(command, 0, output);
  for (size_t i = 0; i < 64; ++i) {
    for (size_t c = 0; c < 3; ++c) assert(output[i][c] == 0);
  }
}

int main() {
  testPresets();
  testLease();
  testPresetClock();
  testRenderer();
  assert(TimeoutMs == 3000 && MaxBrightness == 25);
  Command command;
  assert(accepts("HELLO", command) && command.kind == Kind::Hello);
  assert(accepts("STATUS", command) && command.kind == Kind::Status);
  assert(accepts("ORIENTATION", command) && command.kind == Kind::Orientation);
  assert(accepts("OFF 4294967295", command) && command.sequence == UINT32_MAX);
  assert(accepts("DRAW 12 255 130 0 255 3 00183C7E7E3C1800", command));
  assert(command.kind == Kind::Draw && command.brightness == 25);
  assert(command.red == 255 && command.green == 130 && command.rotation == 3);
  assert(command.bitmap == UINT64_C(0x00183C7E7E3C1800));
  assert(accepts("DRAW 12 255 130 0 25 7 00183C7E7E3C1800", command));
  assert(command.rotation == 3 && command.mirrored);
  const char* invalid[] = {
    "", "HELLO extra", "OFF", "OFF -1", "OFF 4294967296",
    "DRAW 1 256 0 0 63 0 0000000000000000",
    "DRAW 1 255 0 0 63 8 0000000000000000",
    "DRAW 1 255 0 0 63 0 000000000000000Z",
    "DRAW 1 255 0 0 63 0 00000000",
    "DRAW 1 255 0 0 63 0 0000000000000000 extra",
    "DRAW 1 255 0 0 nan 0 0000000000000000"
  };
  for (const char* line : invalid) rejectsAtomically(line, command);
  char fullFrame[MaxLine + 1];
  strcpy(fullFrame, "FRAME 4294967295 255 7 ");
  const size_t prefix = strlen(fullFrame);
  for (size_t i = 0; i < 64; ++i) {
    snprintf(fullFrame + prefix + i * 6, sizeof(fullFrame) - prefix - i * 6,
             "%02X%02X%02X", int(i), int(255 - i), int(i * 3));
  }
  assert(accepts(fullFrame, command) && command.kind == Kind::Frame);
  assert(command.brightness == 25 && command.rotation == 3 && command.mirrored);
  for (size_t i = 0; i < 64; ++i) {
    assert(command.pixels[i][0] == i && command.pixels[i][1] == 255 - i && command.pixels[i][2] == i * 3);
  }
  fullFrame[prefix + 383] = 'Z';
  assert(!accepts(fullFrame, command));
  fullFrame[prefix + 383] = '\0';
  assert(!accepts(fullFrame, command));
  assert(!accepts("FRAME 1 12 8 000000", command));
  assert(!accepts("FRAME 1 12 0 000000", command));
  for (int channel = 0; channel <= 255; ++channel) {
    for (int brightness = 0; brightness <= 255; ++brightness) {
      assert(scaled(channel, brightness) <= 25);
      assert(scaled(channel, brightness) <= channel);
    }
  }
  assert(scaled(255, 255) == 25 && scaled(255, 0) == 0);
  assert(scaled(255, 5) == 5);
  assert(scaled(255, 1) == 3 && scaled(255, 2) == 3 && scaled(255, 3) == 3);
  assert(limitedBrightness(0) == 0 && limitedBrightness(255) == 25);
  for (int flags = 0; flags < 8; ++flags) {
    bool seen[64] = {};
    for (int y = 0; y < 8; ++y) {
      for (int x = 0; x < 8; ++x) {
        const uint8_t index = pixelIndex(flags & 4 ? 7 - x : x, y, flags & 3);
        assert(index < 64 && !seen[index]);
        seen[index] = true;
      }
    }
  }
  assert(pixelIndex(0, 0, 0) == 56 && pixelIndex(7, 0, 0) == 0);
  assert(effectiveRotation(1, 0, false) == 3);
  assert(effectiveRotation(1, 0, true) == 1);
  assert(effectiveRotation(3, 2, true) == 1);
  // Track an asymmetric arrow tip through sensor -> rotation -> physical LED mapping.
  const float gravity[4][2] = {{0, 1}, {1, 0}, {0, -1}, {-1, 0}};
  const uint8_t expectedTurns[4] = {0, 3, 2, 1};
  const uint8_t expectedTipLEDs[4] = {39, 4, 24, 59};
  for (int pose = 0; pose < 4; ++pose) {
    Orientation stable;
    for (uint32_t now = 0; now <= 1200; now += 40) {
      stable.update(gravity[pose][0], gravity[pose][1], 0, now);
    }
    assert(stable.quarterTurn == expectedTurns[pose]);
    assert(pixelIndex(4, 0, effectiveRotation(stable.quarterTurn, 0, false)) ==
           expectedTipLEDs[pose]);
    for (uint8_t offset = 0; offset < 4; ++offset) {
      assert(effectiveRotation(stable.quarterTurn, offset, false) ==
             ((2 + expectedTurns[pose] + offset) & 3));
      assert(effectiveRotation(stable.quarterTurn, offset, true) ==
             ((6 - expectedTurns[pose] + offset) & 3));
    }
  }
  Orientation orientation;
  uint32_t time = 0;
  auto hold = [&](float x, float y, float z) {
    for (int i = 0; i < 30; ++i) {
      time += 40;
      orientation.update(x, y, z, time);
    }
  };
  hold(0, 1, 0);
  assert(orientation.quarterTurn == 0);
  hold(0.7f, 0.7f, 0);
  assert(orientation.quarterTurn == 0);
  hold(1, 0, 0);
  assert(orientation.quarterTurn == 3);
  hold(0, -1, 0);
  assert(orientation.quarterTurn == 2);
  hold(-1, 0, 0);
  assert(orientation.quarterTurn == 1);
  hold(0, 0, 1);
  assert(orientation.quarterTurn == 1 && !orientation.upright);
  hold(2, 0, 0);
  assert(orientation.quarterTurn == 1);
  orientation.update(NAN, 1, 0, time);
  assert(orientation.quarterTurn == 1);
  time = UINT32_MAX - 100;
  hold(0, 1, 0);
  assert(orientation.quarterTurn == 0);
  puts("Firmware v4 protocol, renderer, lease, gravity orientation, reflection, and brightness tests passed.");
}
