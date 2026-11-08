#include "../MicMatrix/Protocol.h"
#include "../MicMatrix/Orientation.h"
#include <assert.h>
#include <stdio.h>

using namespace MatrixProtocol;

bool accepts(const char* text, Command& result) {
  char line[MaxLine + 1];
  assert(strlen(text) <= MaxLine);
  strcpy(line, text);
  return parse(line, result);
}

int main() {
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
  for (const char* line : invalid) assert(!accepts(line, command));
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
  puts("Firmware protocol, gravity orientation, reflection, and exhaustive brightness tests passed.");
}
