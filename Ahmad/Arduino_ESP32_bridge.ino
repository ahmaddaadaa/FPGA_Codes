#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <SPI.h>

// ============================================================
// Wi-Fi access point
// ============================================================

const char* AP_SSID = "RadishCam";
const char* AP_PASSWORD = "radish123";

WebServer server(80);

// ============================================================
// ESP32 -> Cmod A7 SPI wiring
// ============================================================

const int SPI_MOSI = 13;
const int SPI_MISO = 33;
const int SPI_SCLK = 14;
const int SPI_CS   = 32;

const uint32_t SPI_CLOCK_HZ = 1000000UL;

const uint8_t HEADER_1 = 0xA5;
const uint8_t HEADER_2 = 0x5A;

const uint8_t FPGA_RESPONSE_HEADER = 0xC3;
const uint8_t FPGA_ACK = 0x06;

const uint8_t PAYLOAD_BYTES = 64;
const size_t PACKET_BYTES = 70;

const size_t ACK_REPLY_BYTES = 8;
const size_t FPGA_RESULT_BYTES = 28;

SPIClass fpgaSPI(HSPI);

// ============================================================
// 64 x 64 RGB565 image
//
// 64 x 64 pixels = 4096 pixels
// RGB565 = 2 bytes per pixel
// Total = 8192 bytes
// 8192 / 64 = 128 FPGA SPI packets
// ============================================================

const uint16_t IMAGE_WIDTH = 64;
const uint16_t IMAGE_HEIGHT = 64;
const uint16_t IMAGE_PIXELS = IMAGE_WIDTH * IMAGE_HEIGHT;

const size_t FRAME_BYTES = IMAGE_PIXELS * 2;

const uint16_t HTTP_UPLOAD_CHUNK_BYTES = 512;
const uint8_t HTTP_UPLOAD_CHUNKS =
  FRAME_BYTES / HTTP_UPLOAD_CHUNK_BYTES;

const uint8_t FPGA_SPI_CHUNKS =
  FRAME_BYTES / PAYLOAD_BYTES;

uint8_t imageRgb565[FRAME_BYTES];
bool uploadChunkReceived[HTTP_UPLOAD_CHUNKS];

uint8_t frameNumber = 0;
uint8_t lastFailedSpiChunk = 0xFF;

// ============================================================
// FPGA result structure
// ============================================================

struct FpgaColorResult {
  uint8_t frame;
  uint8_t classCode;

  uint16_t redCount;
  uint16_t greenCount;
  uint16_t otherCount;

  uint16_t redPercentX10;
  uint16_t greenPercentX10;

  int16_t redScore;
  int16_t greenScore;

  uint16_t coloredPixels;
  uint16_t pixelsProcessed;
};

// ============================================================
// Web page
// ============================================================

const char INDEX_HTML[] PROGMEM = R"HTML(
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>RadishCam FPGA Colour Test</title>

  <style>
    body {
      font-family: Arial, sans-serif;
      text-align: center;
      background: #f4f6f8;
      margin: 20px;
      color: #1f2937;
    }

    .card {
      max-width: 560px;
      margin: auto;
      background: white;
      padding: 20px;
      border-radius: 14px;
      box-shadow: 0 2px 12px rgba(0,0,0,0.12);
    }

    .button {
      display: inline-block;
      margin: 12px 0;
      padding: 14px 20px;
      border-radius: 9px;
      background: #1f7a3d;
      color: white;
      font-size: 17px;
      font-weight: bold;
      cursor: pointer;
      border: none;
    }

    .button:disabled {
      background: #94a3b8;
      cursor: not-allowed;
    }

    input[type=file] {
      display: none;
    }

    #sourcePreview {
      display: none;
      width: 100%;
      max-width: 430px;
      margin-top: 12px;
      border: 2px solid #334155;
      border-radius: 8px;
    }

    #fpgaPreview {
      width: 100%;
      max-width: 360px;
      height: auto;
      border: 2px solid #334155;
      border-radius: 8px;
      margin-top: 10px;
    }

    #status {
      min-height: 24px;
      font-weight: bold;
      margin-top: 14px;
    }

    #result {
      text-align: left;
      margin-top: 15px;
      padding: 12px;
      background: #eef6ff;
      border-radius: 8px;
      line-height: 1.6;
    }

    .small {
      color: #475569;
      font-size: 14px;
    }
  </style>
</head>

<body>
  <div class="card">
    <h2>RadishCam FPGA Colour Test</h2>

    <p class="small">
      The photo is converted to 64 × 64 RGB565, sent through ESP32 SPI,
      then processed by the FPGA.
    </p>

    <label class="button" for="photoInput">
      Take Fruit Photo
    </label>

    <input
      id="photoInput"
      type="file"
      accept="image/*"
      capture="environment"
    >

    <p class="small">Original iPhone photo:</p>
    <img id="sourcePreview">

    <p class="small">
      Image sent to FPGA: 64 × 64 RGB565
    </p>

    <canvas id="fpgaPreview" width="360" height="360"></canvas>

    <br>

    <button id="sendButton" class="button" disabled>
      Send Image to FPGA
    </button>

    <div id="status">Take a photo to begin.</div>

    <div id="result">
      No FPGA result yet.
    </div>
  </div>

  <script>
    const IMAGE_SIZE = 64;
    const FRAME_BYTES = IMAGE_SIZE * IMAGE_SIZE * 2;

    const HTTP_UPLOAD_CHUNK_BYTES = 512;
    const HTTP_UPLOAD_CHUNKS =
      FRAME_BYTES / HTTP_UPLOAD_CHUNK_BYTES;

    const photoInput = document.getElementById("photoInput");
    const sourcePreview = document.getElementById("sourcePreview");

    const previewCanvas = document.getElementById("fpgaPreview");
    const previewContext = previewCanvas.getContext("2d");

    const rawCanvas = document.createElement("canvas");
    rawCanvas.width = IMAGE_SIZE;
    rawCanvas.height = IMAGE_SIZE;

    const rawContext = rawCanvas.getContext(
      "2d",
      { willReadFrequently: true }
    );

    const sendButton = document.getElementById("sendButton");
    const statusBox = document.getElementById("status");
    const resultBox = document.getElementById("result");

    let currentImage = null;

    function drawFpgaImage() {
      if (!currentImage) {
        return;
      }

      const sourceSide = Math.min(
        currentImage.naturalWidth,
        currentImage.naturalHeight
      );

      const sourceX =
        (currentImage.naturalWidth - sourceSide) / 2;

      const sourceY =
        (currentImage.naturalHeight - sourceSide) / 2;

      rawContext.clearRect(0, 0, IMAGE_SIZE, IMAGE_SIZE);
      rawContext.imageSmoothingEnabled = true;
      rawContext.imageSmoothingQuality = "high";

      rawContext.drawImage(
        currentImage,
        sourceX,
        sourceY,
        sourceSide,
        sourceSide,
        0,
        0,
        IMAGE_SIZE,
        IMAGE_SIZE
      );

      previewContext.clearRect(
        0,
        0,
        previewCanvas.width,
        previewCanvas.height
      );

      previewContext.imageSmoothingEnabled = true;
      previewContext.imageSmoothingQuality = "high";

      previewContext.drawImage(
        rawCanvas,
        0,
        0,
        IMAGE_SIZE,
        IMAGE_SIZE,
        0,
        0,
        previewCanvas.width,
        previewCanvas.height
      );
    }

    function bytesToHex(bytes) {
      let hexText = "";

      for (let i = 0; i < bytes.length; i++) {
        hexText += bytes[i]
          .toString(16)
          .padStart(2, "0")
          .toUpperCase();
      }

      return hexText;
    }

    async function getJson(response) {
      const text = await response.text();

      try {
        return JSON.parse(text);
      } catch {
        throw new Error("ESP32 response: " + text);
      }
    }

    function formatPercent(valueX10) {
      return (valueX10 / 10).toFixed(1) + "%";
    }

    photoInput.addEventListener("change", function () {
      const file = photoInput.files[0];

      if (!file) {
        return;
      }

      sendButton.disabled = true;
      resultBox.textContent = "";
      statusBox.textContent = "Loading iPhone photo...";

      const imageUrl = URL.createObjectURL(file);
      const image = new Image();

      image.onload = function () {
        currentImage = image;

        sourcePreview.src = imageUrl;
        sourcePreview.style.display = "block";

        drawFpgaImage();

        sendButton.disabled = false;

        statusBox.textContent =
          "Photo ready. Press Send Image to FPGA.";
      };

      image.onerror = function () {
        statusBox.textContent = "Could not load image.";
      };

      image.src = imageUrl;
    });

    sendButton.addEventListener("click", async function () {
      if (!currentImage) {
        return;
      }

      try {
        sendButton.disabled = true;
        resultBox.textContent = "";

        drawFpgaImage();

        const imageData = rawContext.getImageData(
          0,
          0,
          IMAGE_SIZE,
          IMAGE_SIZE
        );

        const rgba = imageData.data;
        const rgb565Bytes = new Uint8Array(FRAME_BYTES);

        let outputIndex = 0;

        for (let i = 0; i < rgba.length; i += 4) {
          const red = rgba[i];
          const green = rgba[i + 1];
          const blue = rgba[i + 2];

          const rgb565 =
            ((red & 0xF8) << 8) |
            ((green & 0xFC) << 3) |
            (blue >> 3);

          rgb565Bytes[outputIndex++] = rgb565 >> 8;
          rgb565Bytes[outputIndex++] = rgb565 & 0xFF;
        }

        statusBox.textContent = "Starting image upload to ESP32...";

        let response = await fetch("/upload_start", {
          method: "POST"
        });

        let result = await getJson(response);

        if (!response.ok || !result.ok) {
          throw new Error(
            result.message || "ESP32 could not start image upload."
          );
        }

        for (let chunk = 0; chunk < HTTP_UPLOAD_CHUNKS; chunk++) {
          const start = chunk * HTTP_UPLOAD_CHUNK_BYTES;
          const end = start + HTTP_UPLOAD_CHUNK_BYTES;

          const chunkHex = bytesToHex(
            rgb565Bytes.slice(start, end)
          );

          statusBox.textContent =
            "Uploading image to ESP32: " +
            (chunk + 1) + " / " + HTTP_UPLOAD_CHUNKS;

          response = await fetch(
            "/upload_chunk?chunk=" + chunk,
            {
              method: "POST",
              headers: {
                "Content-Type": "text/plain"
              },
              body: chunkHex
            }
          );

          result = await getJson(response);

          if (!response.ok || !result.ok) {
            throw new Error(
              result.message || "ESP32 image upload failed."
            );
          }
        }

        statusBox.textContent =
          "Sending 128 image packets to FPGA...";

        response = await fetch("/send_to_fpga", {
          method: "POST"
        });

        result = await getJson(response);

        if (!response.ok || !result.ok) {
          throw new Error(
            result.message || "FPGA image processing failed."
          );
        }

        statusBox.textContent =
          "Success: FPGA processed the image.";

        resultBox.innerHTML =
          "<b>FPGA classification:</b> " +
          result.class_name + "<br><br>" +

          "<b>FPGA red pixels:</b> " +
          result.red + " (" +
          formatPercent(result.red_pct_x10) + ")<br>" +

          "<b>FPGA green pixels:</b> " +
          result.green + " (" +
          formatPercent(result.green_pct_x10) + ")<br>" +

          "<b>FPGA other pixels:</b> " +
          result.other + "<br><br>" +

          "<b>Red weighted score:</b> " +
          result.red_score + "<br>" +

          "<b>Green weighted score:</b> " +
          result.green_score + "<br><br>" +

          "<b>Pixels processed:</b> " +
          result.pixels_processed + "<br>" +

          "<b>SPI packets acknowledged:</b> " +
          result.fpga_packets + " / " +
          result.fpga_packets + "<br>" +

          "<b>ESP32 → FPGA transfer:</b> " +
          result.spi_us + " us";

      } catch (error) {
        statusBox.textContent = "Transfer failed.";
        resultBox.textContent = error.message;
      }

      sendButton.disabled = false;
    });
  </script>
</body>
</html>
)HTML";

// ============================================================
// Upload helpers
// ============================================================

void clearUploadState() {
  for (uint8_t i = 0; i < HTTP_UPLOAD_CHUNKS; i++) {
    uploadChunkReceived[i] = false;
  }
}

bool allUploadChunksReceived() {
  for (uint8_t i = 0; i < HTTP_UPLOAD_CHUNKS; i++) {
    if (!uploadChunkReceived[i]) {
      return false;
    }
  }

  return true;
}

int hexValue(char value) {
  if (value >= '0' && value <= '9') {
    return value - '0';
  }

  if (value >= 'A' && value <= 'F') {
    return value - 'A' + 10;
  }

  if (value >= 'a' && value <= 'f') {
    return value - 'a' + 10;
  }

  return -1;
}

bool decodeHexToBytes(
  const String& hexText,
  uint8_t* destination,
  size_t byteCount
) {
  if (hexText.length() != byteCount * 2) {
    return false;
  }

  for (size_t i = 0; i < byteCount; i++) {
    int highNibble = hexValue(hexText.charAt(i * 2));
    int lowNibble = hexValue(hexText.charAt(i * 2 + 1));

    if (highNibble < 0 || lowNibble < 0) {
      return false;
    }

    destination[i] =
      (uint8_t)((highNibble << 4) | lowNibble);
  }

  return true;
}

// ============================================================
// SPI helpers
// ============================================================

void spiTransferBuffer(
  const uint8_t* tx,
  uint8_t* rx,
  size_t count
) {
  fpgaSPI.beginTransaction(
    SPISettings(SPI_CLOCK_HZ, MSBFIRST, SPI_MODE0)
  );

  digitalWrite(SPI_CS, LOW);
  delayMicroseconds(2);

  for (size_t i = 0; i < count; i++) {
    rx[i] = fpgaSPI.transfer(tx[i]);
  }

  delayMicroseconds(3);

  digitalWrite(SPI_CS, HIGH);
  fpgaSPI.endTransaction();
}

uint16_t readU16BE(const uint8_t* data) {
  return ((uint16_t)data[0] << 8) | data[1];
}

int16_t readI16BE(const uint8_t* data) {
  return (int16_t)readU16BE(data);
}

const char* className(uint8_t classCode) {
  if (classCode == 1) {
    return "Red dominant";
  }

  if (classCode == 2) {
    return "Green dominant";
  }

  return "Unknown / insufficient colour";
}

// ============================================================
// Send one 64-byte image packet to FPGA
// ============================================================

bool sendImagePacketToFpga(
  uint8_t frame,
  uint8_t chunk
) {
  uint8_t packet[PACKET_BYTES] = {0};
  uint8_t ignored[PACKET_BYTES] = {0};

  uint8_t ackRequest[ACK_REPLY_BYTES] = {0};
  uint8_t ackReply[ACK_REPLY_BYTES] = {0};

  size_t frameOffset =
    (size_t)chunk * PAYLOAD_BYTES;

  uint8_t checksum = 0;

  packet[0] = HEADER_1;
  packet[1] = HEADER_2;

  packet[2] = frame;
  checksum ^= frame;

  packet[3] = chunk;
  checksum ^= chunk;

  packet[4] = PAYLOAD_BYTES;
  checksum ^= PAYLOAD_BYTES;

  for (uint8_t i = 0; i < PAYLOAD_BYTES; i++) {
    uint8_t imageByte = imageRgb565[frameOffset + i];

    packet[5 + i] = imageByte;
    checksum ^= imageByte;
  }

  packet[PACKET_BYTES - 1] = checksum;

  // Send the image packet.
  spiTransferBuffer(packet, ignored, PACKET_BYTES);

  delayMicroseconds(20);

  // Read the normal 8-byte ACK packet.
  spiTransferBuffer(
    ackRequest,
    ackReply,
    ACK_REPLY_BYTES
  );

  uint16_t fpgaEdges =
    ((uint16_t)ackReply[6] << 8) |
    ackReply[7];

  bool pass =
    ackReply[0] == FPGA_RESPONSE_HEADER &&
    ackReply[1] == FPGA_ACK &&
    ackReply[2] == frame &&
    ackReply[3] == chunk &&
    ackReply[4] == PAYLOAD_BYTES &&
    ackReply[5] == checksum &&
    fpgaEdges == (PACKET_BYTES * 8);

  if (chunk == 0 ||
      chunk == FPGA_SPI_CHUNKS - 1 ||
      (chunk % 16) == 15 ||
      !pass) {

    Serial.printf(
      "FPGA SPI: frame %u | packet %u / %u | %s\n",
      frame,
      chunk + 1,
      FPGA_SPI_CHUNKS,
      pass ? "ACK" : "FAIL"
    );
  }

  if (!pass) {
    Serial.printf(
      "Reply: %02X %02X %02X %02X %02X %02X %02X %02X\n",
      ackReply[0],
      ackReply[1],
      ackReply[2],
      ackReply[3],
      ackReply[4],
      ackReply[5],
      ackReply[6],
      ackReply[7]
    );
  }

  return pass;
}

// ============================================================
// Send entire 64x64 RGB565 image
// ============================================================

bool sendFullImageToFpga(
  uint8_t frame,
  uint32_t& spiTimeUs
) {
  uint32_t startUs = micros();

  lastFailedSpiChunk = 0xFF;

  for (uint8_t chunk = 0;
       chunk < FPGA_SPI_CHUNKS;
       chunk++) {

    if (!sendImagePacketToFpga(frame, chunk)) {
      lastFailedSpiChunk = chunk;
      spiTimeUs = micros() - startUs;
      return false;
    }

    if ((chunk % 8) == 7) {
      delay(0);
    }
  }

  spiTimeUs = micros() - startUs;
  return true;
}

// ============================================================
// Read final FPGA colour result
// ============================================================

bool readFpgaColorResult(FpgaColorResult& result) {
  uint8_t request[FPGA_RESULT_BYTES] = {0};
  uint8_t reply[FPGA_RESULT_BYTES] = {0};

  spiTransferBuffer(
    request,
    reply,
    FPGA_RESULT_BYTES
  );

  bool valid =
    reply[0] == FPGA_RESPONSE_HEADER &&
    reply[1] == FPGA_ACK &&
    reply[8] == 0x01;

  if (!valid) {
    Serial.println("FPGA colour-result packet was invalid.");

    Serial.print("Result reply: ");

    for (size_t i = 0; i < FPGA_RESULT_BYTES; i++) {
      Serial.printf("%02X ", reply[i]);
    }

    Serial.println();

    return false;
  }

  result.frame = reply[2];
  result.classCode = reply[9];

  result.redCount = readU16BE(&reply[10]);
  result.greenCount = readU16BE(&reply[12]);
  result.otherCount = readU16BE(&reply[14]);

  result.redPercentX10 = readU16BE(&reply[16]);
  result.greenPercentX10 = readU16BE(&reply[18]);

  result.redScore = readI16BE(&reply[20]);
  result.greenScore = readI16BE(&reply[22]);

  result.coloredPixels = readU16BE(&reply[24]);
  result.pixelsProcessed = readU16BE(&reply[26]);

  return true;
}

// ============================================================
// HTTP handlers
// ============================================================

void handleHome() {
  server.send_P(200, "text/html", INDEX_HTML);
}

void handleUploadStart() {
  clearUploadState();

  Serial.println();
  Serial.println("========== IPHONE IMAGE UPLOAD START ==========");
  Serial.println("Expected image: 64 x 64 RGB565");
  Serial.printf(
    "Expected bytes: %u\n",
    (unsigned int)FRAME_BYTES
  );

  server.send(
    200,
    "application/json",
    "{\"ok\":true}"
  );
}

void handleUploadChunk() {
  if (!server.hasArg("chunk")) {
    server.send(
      400,
      "application/json",
      "{\"ok\":false,\"message\":\"Missing upload chunk number.\"}"
    );
    return;
  }

  int chunkIndex = server.arg("chunk").toInt();

  if (chunkIndex < 0 ||
      chunkIndex >= HTTP_UPLOAD_CHUNKS) {

    server.send(
      400,
      "application/json",
      "{\"ok\":false,\"message\":\"Invalid upload chunk number.\"}"
    );
    return;
  }

  String hexData = server.arg("plain");

  size_t memoryOffset =
    (size_t)chunkIndex * HTTP_UPLOAD_CHUNK_BYTES;

  bool decoded = decodeHexToBytes(
    hexData,
    imageRgb565 + memoryOffset,
    HTTP_UPLOAD_CHUNK_BYTES
  );

  if (!decoded) {
    server.send(
      400,
      "application/json",
      "{\"ok\":false,\"message\":\"Invalid image upload data.\"}"
    );
    return;
  }

  uploadChunkReceived[chunkIndex] = true;

  Serial.printf(
    "iPhone image upload: %d / %d\n",
    chunkIndex + 1,
    HTTP_UPLOAD_CHUNKS
  );

  server.send(
    200,
    "application/json",
    "{\"ok\":true}"
  );
}

void handleSendToFpga() {
  if (!allUploadChunksReceived()) {
    server.send(
      400,
      "application/json",
      "{\"ok\":false,\"message\":\"Image upload is incomplete.\"}"
    );
    return;
  }

  Serial.println();
  Serial.println("========== STARTING FPGA SPI TRANSFER ==========");
  Serial.printf(
    "Image bytes: %u\n",
    (unsigned int)FRAME_BYTES
  );

  Serial.printf(
    "Expected FPGA packets: %u\n",
    FPGA_SPI_CHUNKS
  );

  uint32_t spiTimeUs = 0;

  bool spiPassed = sendFullImageToFpga(
    frameNumber,
    spiTimeUs
  );

  if (!spiPassed) {
    char response[180];

    snprintf(
      response,
      sizeof(response),
      "{\"ok\":false,\"message\":\"FPGA rejected SPI packet %u. Check FPGA bitstream, power, GND, and SPI wiring.\"}",
      lastFailedSpiChunk
    );

    server.send(500, "application/json", response);
    return;
  }

  delayMicroseconds(50);

  FpgaColorResult fpgaResult;

  if (!readFpgaColorResult(fpgaResult)) {
    server.send(
      500,
      "application/json",
      "{\"ok\":false,\"message\":\"FPGA did not return a valid colour result.\"}"
    );
    return;
  }

  if (fpgaResult.frame != frameNumber ||
      fpgaResult.pixelsProcessed != IMAGE_PIXELS) {

    server.send(
      500,
      "application/json",
      "{\"ok\":false,\"message\":\"FPGA returned an incomplete image result.\"}"
    );
    return;
  }

  Serial.println();
  Serial.println("========== FPGA COLOUR RESULT ==========");

  Serial.printf(
    "Class: %s\n",
    className(fpgaResult.classCode)
  );

  Serial.printf(
    "Red: %u pixels = %u.%u%%\n",
    fpgaResult.redCount,
    fpgaResult.redPercentX10 / 10,
    fpgaResult.redPercentX10 % 10
  );

  Serial.printf(
    "Green: %u pixels = %u.%u%%\n",
    fpgaResult.greenCount,
    fpgaResult.greenPercentX10 / 10,
    fpgaResult.greenPercentX10 % 10
  );

  Serial.printf(
    "Other: %u pixels\n",
    fpgaResult.otherCount
  );

  Serial.printf(
    "Red score: %d\n",
    fpgaResult.redScore
  );

  Serial.printf(
    "Green score: %d\n",
    fpgaResult.greenScore
  );

  Serial.printf(
    "Processed pixels: %u\n",
    fpgaResult.pixelsProcessed
  );

  Serial.println("========================================");

  char response[350];

  snprintf(
    response,
    sizeof(response),
    "{\"ok\":true,"
    "\"frame\":%u,"
    "\"fpga_packets\":%u,"
    "\"spi_us\":%lu,"
    "\"class_name\":\"%s\","
    "\"red\":%u,"
    "\"green\":%u,"
    "\"other\":%u,"
    "\"red_pct_x10\":%u,"
    "\"green_pct_x10\":%u,"
    "\"red_score\":%d,"
    "\"green_score\":%d,"
    "\"pixels_processed\":%u}",
    fpgaResult.frame,
    FPGA_SPI_CHUNKS,
    (unsigned long)spiTimeUs,
    className(fpgaResult.classCode),
    fpgaResult.redCount,
    fpgaResult.greenCount,
    fpgaResult.otherCount,
    fpgaResult.redPercentX10,
    fpgaResult.greenPercentX10,
    fpgaResult.redScore,
    fpgaResult.greenScore,
    fpgaResult.pixelsProcessed
  );

  frameNumber++;

  server.send(200, "application/json", response);
}

// ============================================================
// Setup and loop
// ============================================================

void setup() {
  Serial.begin(115200);
  delay(800);

  clearUploadState();

  pinMode(SPI_CS, OUTPUT);
  digitalWrite(SPI_CS, HIGH);

  fpgaSPI.begin(
    SPI_SCLK,
    SPI_MISO,
    SPI_MOSI,
    SPI_CS
  );

  WiFi.mode(WIFI_AP);

  if (!WiFi.softAP(AP_SSID, AP_PASSWORD)) {
    Serial.println("Could not create RadishCam Wi-Fi network.");

    while (true) {
      delay(1000);
    }
  }

  server.on("/", HTTP_GET, handleHome);
  server.on("/upload_start", HTTP_POST, handleUploadStart);
  server.on("/upload_chunk", HTTP_POST, handleUploadChunk);
  server.on("/send_to_fpga", HTTP_POST, handleSendToFpga);

  server.begin();

  Serial.println();
  Serial.println("RadishCam iPhone -> ESP32 -> FPGA started.");

  Serial.print("Wi-Fi name: ");
  Serial.println(AP_SSID);

  Serial.print("Password: ");
  Serial.println(AP_PASSWORD);

  Serial.print("Open Safari: http://");
  Serial.println(WiFi.softAPIP());
}

void loop() {
  server.handleClient();
}