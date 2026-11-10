#include <Adafruit_NeoPixel.h>
#include <sensor/imu/qmi8658/SensorQMI8658.hpp>
#include <Wire.h>
#include "Protocol.h"
#include "Orientation.h"
#include "Renderer.h"

Adafruit_NeoPixel pixels(64, 14, NEO_RGB + NEO_KHZ800);
char inputLine[MatrixProtocol::MaxLine + 1];
size_t inputLength = 0;
bool discarding = false;
MatrixProtocol::DisplayLease displayLease;
MatrixProtocol::PresetClock presetClock;
uint32_t lastRender = 0;
uint8_t renderedPixels[64][3] = {};
bool haveRendered = false;
SensorQMI8658 imu;
MatrixProtocol::Orientation orientation;
MatrixProtocol::Command currentFrame;
bool imuInitialized = false;
bool haveSample = false;
uint32_t lastSample = 0, lastImuPoll = 0;
float accelX = 0, accelY = 0, accelZ = 0;

bool imuHealthy() {
  return imuInitialized && haveSample && uint32_t(millis() - lastSample) < 600;
}

void showFrame(const uint8_t frame[64][3]) {
  if (haveRendered && memcmp(frame, renderedPixels, sizeof(renderedPixels)) == 0) return;
  for (uint8_t i = 0; i < 64; ++i) {
    pixels.setPixelColor(i, frame[i][0], frame[i][1], frame[i][2]);
  }
  pixels.show();
  memcpy(renderedPixels, frame, sizeof(renderedPixels));
  haveRendered = true;
}

void renderFrame(uint32_t now) {
  presetClock.update(now);
  uint8_t preset[64][3];
  const uint8_t (*source)[3] = currentFrame.pixels;
  if (currentFrame.kind == MatrixProtocol::Kind::Preset) {
    MatrixProtocol::renderPreset(currentFrame, presetClock.elapsedMs, preset);
    source = preset;
  }
  uint8_t frame[64][3] = {};
  const uint8_t rotation = MatrixProtocol::effectiveRotation(
    orientation.quarterTurn, currentFrame.rotation, currentFrame.mirrored);
  for (uint8_t y = 0; y < 8; ++y) {
    for (uint8_t x = 0; x < 8; ++x) {
      const uint8_t* rgb = source[y * 8 + x];
      const uint8_t index = MatrixProtocol::pixelIndex(
        currentFrame.mirrored ? 7 - x : x, y, rotation);
      for (uint8_t channel = 0; channel < 3; ++channel) {
        frame[index][channel] = MatrixProtocol::scaled(rgb[channel], currentFrame.brightness);
      }
    }
  }
  showFrame(frame);
  lastRender = now;
}

void clearDisplay() {
  const uint8_t blank[64][3] = {};
  showFrame(blank);
  displayLease.stop();
}

void expireDisplay(uint32_t now) {
  if (displayLease.active && !displayLease.valid(now)) {
    clearDisplay();
    Serial.println("TIMEOUT");
  }
}

void processLine() {
  expireDisplay(millis());
  if (inputLength == 0) return;
  inputLine[inputLength] = '\0';
  MatrixProtocol::Command command;
  if (!MatrixProtocol::parse(inputLine, command)) {
    Serial.println("ERR command");
    return;
  }
  if (command.kind == MatrixProtocol::Kind::Hello) {
    Serial.println(imuHealthy() ? "MATRIX 4 8 8 25 PRESET1" : "ERR imu-unavailable");
    return;
  }
  if (command.kind == MatrixProtocol::Kind::Orientation) {
    if (!imuHealthy()) {
      Serial.println("ERR imu-unavailable");
      return;
    }
    Serial.printf("ORIENT %u %d %d %d %u\n", orientation.quarterTurn,
      int(lroundf(accelX * 1000)), int(lroundf(accelY * 1000)),
      int(lroundf(accelZ * 1000)), orientation.upright ? 1 : 0);
    return;
  }
  if (command.kind == MatrixProtocol::Kind::Status) {
    uint8_t lit = 0, red = 0, green = 0, blue = 0;
    for (uint8_t i = 0; i < 64; ++i) {
      const uint32_t color = pixels.getPixelColor(i);
      if (color) ++lit;
      red = max(red, uint8_t(color >> 16));
      green = max(green, uint8_t(color >> 8));
      blue = max(blue, uint8_t(color));
    }
    Serial.printf("STATE %u %u %u %u\n", lit, red, green, blue);
    return;
  }
  if (command.kind == MatrixProtocol::Kind::Off) {
    clearDisplay();
  } else if (command.kind == MatrixProtocol::Kind::Keep) {
    if (!displayLease.valid(millis())) {
      clearDisplay();
      Serial.println("ERR inactive");
      return;
    }
    if (!imuHealthy()) {
      clearDisplay();
      Serial.println("ERR imu-unavailable");
      return;
    }
    if (!displayLease.keep(millis())) {
      clearDisplay();
      Serial.println("ERR inactive");
      return;
    }
  } else {
    if (!imuHealthy()) {
      clearDisplay();
      Serial.println("ERR imu-unavailable");
      return;
    }
    currentFrame = command;
    const uint32_t now = millis();
    presetClock.reset(now);
    displayLease.start(now);
    renderFrame(now);
  }
  Serial.printf("OK %lu\n", static_cast<unsigned long>(command.sequence));
}

void setup() {
  pixels.begin();
  clearDisplay();
  Serial.setRxBufferSize(1024);
  Serial.begin(115200);
  Wire.begin(11, 12);
  Wire.setTimeOut(20);
  imuInitialized = imu.begin(Wire, QMI8658_L_SLAVE_ADDRESS, 11, 12) &&
    imu.disableGyro() &&
    imu.configAccel(AccelFullScaleRange::FS_2G, 56.0f, SensorQMI8658::LpfMode::MODE_3) &&
    imu.enableAccel();
  if (!imuInitialized) Serial.println("ERR imu-initialization");
}

void loop() {
  const uint32_t now = millis();
  presetClock.update(now);
  expireDisplay(now);
  if (imuInitialized && uint32_t(now - lastImuPoll) >= 40) {
    lastImuPoll = now;
    AccelerometerData acceleration;
    if (imu.isDataReady(static_cast<uint8_t>(ImuBase::DataReadyMask::ACCEL)) &&
        imu.readAccel(acceleration)) {
      accelX = acceleration.mps2.x / 9.80665f;
      accelY = acceleration.mps2.y / 9.80665f;
      accelZ = acceleration.mps2.z / 9.80665f;
      if (isfinite(accelX) && isfinite(accelY) && isfinite(accelZ)) {
        haveSample = true;
        lastSample = now;
        if (orientation.update(accelX, accelY, accelZ, now) && displayLease.valid(now)) {
          renderFrame(now);
        }
      }
    }
  }
  if (displayLease.active && !imuHealthy()) {
    clearDisplay();
    Serial.println("ERR imu-unavailable");
  }
  // Bound each pass so even a continuous malformed stream cannot starve the timeout.
  for (size_t budget = 0; budget < 512 && Serial.available() > 0; ++budget) {
    const int byte = Serial.read();
    if (byte < 0) break;
    if (byte == '\n') {
      if (discarding) Serial.println("ERR line-too-long");
      else processLine();
      inputLength = 0;
      discarding = false;
    } else if (!discarding) {
      if (byte < 32 && byte != '\r') {
        discarding = true;
      } else if (inputLength == MatrixProtocol::MaxLine) {
        discarding = true;
      } else {
        inputLine[inputLength++] = static_cast<char>(byte);
      }
    }
  }
  const uint32_t renderNow = millis();
  expireDisplay(renderNow);
  if (displayLease.valid(renderNow) && MatrixProtocol::presetAnimated(currentFrame) &&
      uint32_t(renderNow - lastRender) >= MatrixProtocol::AnimationIntervalMs) {
    renderFrame(renderNow);
  }
  delay(1);
}
