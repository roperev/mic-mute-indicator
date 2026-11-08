#pragma once

#include <math.h>
#include <stdint.h>

namespace MatrixProtocol {
class Orientation {
 public:
  uint8_t quarterTurn = 0;
  bool upright = false;

  bool update(float ax, float ay, float az, uint32_t now) {
    const float magnitudeSquared = ax * ax + ay * ay + az * az;
    if (!isfinite(magnitudeSquared) || magnitudeSquared < 0.36f || magnitudeSquared > 1.96f) {
      upright = false;
      candidate = quarterTurn;
      candidateSince = now;
      return false;
    }
    if (!seeded) {
      x = ax; y = ay; z = az;
      seeded = true;
    } else {
      x += 0.25f * (ax - x);
      y += 0.25f * (ay - y);
      z += 0.25f * (az - z);
    }
    const float absX = fabsf(x), absY = fabsf(y);
    upright = x * x + y * y >= 0.2025f;
    if (!upright || (absX < absY * 1.25f && absY < absX * 1.25f)) {
      candidate = quarterTurn;
      candidateSince = now;
      return false;
    }
    // The sensor's X axis has opposite handedness to the display's clockwise rotation.
    const uint8_t next = absX > absY ? (x > 0 ? 3 : 1) : (y > 0 ? 0 : 2);
    if (next != candidate) {
      candidate = next;
      candidateSince = now;
    }
    if (next != quarterTurn && uint32_t(now - candidateSince) >= 200) {
      quarterTurn = next;
      return true;
    }
    return false;
  }

 private:
  float x = 0, y = 0, z = 0;
  bool seeded = false;
  uint8_t candidate = 0;
  uint32_t candidateSince = 0;
};

inline uint8_t effectiveRotation(uint8_t automatic, uint8_t offset, bool mirrored) {
  // A reflected matrix reverses rotation handedness, not just the bitmap.
  return (2 + offset + (mirrored ? (4 - automatic) : automatic)) & 3;
}
}
