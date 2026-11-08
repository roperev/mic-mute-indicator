#pragma once

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

namespace MatrixProtocol {
constexpr uint8_t MaxBrightness = 25;
constexpr uint8_t MinBrightness = 3;
constexpr uint32_t TimeoutMs = 3000;
constexpr size_t MaxLine = 448;

enum class Kind { Hello, Status, Orientation, Off, Draw, Frame };

struct Command {
  Kind kind = Kind::Hello;
  uint32_t sequence = 0;
  uint8_t red = 0, green = 0, blue = 0, brightness = 0, rotation = 0;
  bool mirrored = false;
  uint64_t bitmap = 0;
  uint8_t pixels[64][3] = {};
};

inline uint8_t limitedBrightness(uint8_t value) {
  if (value == 0) return 0;
  if (value < MinBrightness) return MinBrightness;
  return value > MaxBrightness ? MaxBrightness : value;
}

inline bool decimal(const char* text, uint32_t maximum, uint32_t& value) {
  if (!text || !*text) return false;
  uint32_t result = 0;
  for (const char* p = text; *p; ++p) {
    if (*p < '0' || *p > '9') return false;
    const uint32_t digit = *p - '0';
    if (result > maximum / 10 ||
        (result == maximum / 10 && digit > maximum % 10)) return false;
    result = result * 10 + digit;
  }
  value = result;
  return true;
}

inline bool parse(char* line, Command& result) {
  char* tokens[10] = {};
  char* context = nullptr;
  size_t count = 0;
  for (char* token = strtok_r(line, " \r", &context); token;
       token = strtok_r(nullptr, " \r", &context)) {
    if (count == 10) return false;
    tokens[count++] = token;
  }
  if (count == 1 && strcmp(tokens[0], "HELLO") == 0) {
    result = Command{};
    return true;
  }
  if (count == 1 && strcmp(tokens[0], "STATUS") == 0) {
    result = Command{};
    result.kind = Kind::Status;
    return true;
  }
  if (count == 1 && strcmp(tokens[0], "ORIENTATION") == 0) {
    result = Command{};
    result.kind = Kind::Orientation;
    return true;
  }
  Command command;
  if (count == 2 && strcmp(tokens[0], "OFF") == 0) {
    if (!decimal(tokens[1], UINT32_MAX, command.sequence)) return false;
    command.kind = Kind::Off;
  } else if (count == 5 && strcmp(tokens[0], "FRAME") == 0) {
    uint32_t brightness, flags;
    if (!decimal(tokens[1], UINT32_MAX, command.sequence) ||
        !decimal(tokens[2], 255, brightness) || !decimal(tokens[3], 7, flags) ||
        strlen(tokens[4]) != 384) return false;
    for (size_t i = 0; i < 384; ++i) {
      const char c = tokens[4][i];
      uint8_t nibble;
      if (c >= '0' && c <= '9') nibble = c - '0';
      else if (c >= 'a' && c <= 'f') nibble = c - 'a' + 10;
      else if (c >= 'A' && c <= 'F') nibble = c - 'A' + 10;
      else return false;
      uint8_t& channel = command.pixels[i / 6][(i % 6) / 2];
      channel = (channel << 4) | nibble;
    }
    command.kind = Kind::Frame;
    command.brightness = limitedBrightness(brightness);
    command.rotation = flags & 3;
    command.mirrored = (flags & 4) != 0;
  } else if (count == 8 && strcmp(tokens[0], "DRAW") == 0) {
    uint32_t red, green, blue, brightness, rotation;
    if (!decimal(tokens[1], UINT32_MAX, command.sequence) ||
        !decimal(tokens[2], 255, red) || !decimal(tokens[3], 255, green) ||
        !decimal(tokens[4], 255, blue) || !decimal(tokens[5], 255, brightness) ||
        !decimal(tokens[6], 7, rotation) || strlen(tokens[7]) != 16) return false;
    uint64_t bitmap = 0;
    for (size_t i = 0; i < 16; ++i) {
      const char c = tokens[7][i];
      uint8_t nibble;
      if (c >= '0' && c <= '9') nibble = c - '0';
      else if (c >= 'a' && c <= 'f') nibble = c - 'a' + 10;
      else if (c >= 'A' && c <= 'F') nibble = c - 'A' + 10;
      else return false;
      bitmap = (bitmap << 4) | nibble;
    }
    command.kind = Kind::Draw;
    command.red = red;
    command.green = green;
    command.blue = blue;
    command.brightness = limitedBrightness(brightness);
    command.rotation = rotation & 3;
    command.mirrored = (rotation & 4) != 0;
    command.bitmap = bitmap;
    for (size_t i = 0; i < 64; ++i) {
      if ((bitmap >> (63 - i)) & 1) {
        command.pixels[i][0] = red;
        command.pixels[i][1] = green;
        command.pixels[i][2] = blue;
      }
    }
  } else {
    return false;
  }
  result = command;
  return true;
}

inline uint8_t scaled(uint8_t channel, uint8_t brightness) {
  const uint8_t limited = limitedBrightness(brightness);
  return uint16_t(channel) * limited / 255;
}

inline uint8_t pixelIndex(uint8_t x, uint8_t y, uint8_t rotation) {
  uint8_t column = x, row = y;
  switch (rotation) {
    case 1: column = 7 - y; row = x; break;
    case 2: column = 7 - x; row = 7 - y; break;
    case 3: column = y; row = 7 - x; break;
  }
  // Waveshare's font example specifies top-right, progressive columns.
  return (7 - column) * 8 + row;
}
}
