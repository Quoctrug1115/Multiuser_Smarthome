#include <Arduino.h>
#include <WiFi.h>
#include <PubSubClient.h>
#include <DHT.h>
#include <ArduinoJson.h>

// ============================================================================
// 1. CẤU HÌNH WIFI & MQTT BROKER
// ============================================================================
const char* WIFI_SSID     = "Wokwi-GUEST";
const char* WIFI_PASSWORD = "";

const char* MQTT_BROKER   = "broker.emqx.io";
const int   MQTT_PORT     = 1883;
const char* CHIP_ID       = "QTRUNG000001";

// Các topic chuẩn đồng bộ với Backend Rust (backend/src/main.rs)
const char* TOPIC_LIGHT_BASE    = "smarthome/QTRUNG000001/light";
const char* TOPIC_LIGHT_CTRL    = "smarthome/QTRUNG000001/light/control";
const char* TOPIC_LIGHT_STATE   = "smarthome/QTRUNG000001/light/state";

const char* TOPIC_FAN_BASE      = "smarthome/QTRUNG000001/fan";
const char* TOPIC_FAN_CTRL      = "smarthome/QTRUNG000001/fan/control";
const char* TOPIC_FAN_STATE     = "smarthome/QTRUNG000001/fan/state";

const char* TOPIC_TELEMETRY     = "smarthome/QTRUNG000001/telemetry";
const char* TOPIC_AVAIL         = "smarthome/QTRUNG000001/availability";
const char* TOPIC_DISCOVERY     = "smarthome/discovery";
const char* TOPIC_DISCOVERY_REQ = "smarthome/discovery/request";

// ============================================================================
// 2. KHAI BÁO CHÂN GPIO (KHỚP 100% VỚI diagram.json)
// ============================================================================
#define LED_LIGHT_PIN 2   // LED vàng - Đèn
#define LED_FAN_PIN   4   // LED xanh - Quạt
#define BTN_LIGHT_PIN 12  // Nút nhấn Đèn (INPUT_PULLUP -> GND)
#define BTN_FAN_PIN   14  // Nút nhấn Quạt (INPUT_PULLUP -> GND)
#define DHT_PIN       15  // Cảm biến DHT22
#define DHT_TYPE      DHT22
#define LDR_PIN       36  // Chân VP - Cảm biến ánh sáng LDR (AO)
#define PIR_PIN       13  // Cảm biến chuyển động PIR (OUT)

// ============================================================================
// 3. BIẾN TRẠNG THÁI & ĐỐI TƯỢNG TOÀN CỤC
// ============================================================================
WiFiClient espClient;
PubSubClient mqttClient(espClient);
DHT dht(DHT_PIN, DHT_TYPE);

bool lightState = false;
bool fanState   = false;

// Chống dội nút nhấn không chặn vòng lặp (non-blocking debounce)
bool lastReadingLight = HIGH;
bool stableBtnLight   = HIGH;
unsigned long lastDebounceLightMs = 0;

bool lastReadingFan = HIGH;
bool stableBtnFan   = HIGH;
unsigned long lastDebounceFanMs = 0;

const unsigned long DEBOUNCE_DELAY_MS = 50;

// Timer gửi cảm biến định kỳ & theo dõi chuyển động PIR
unsigned long lastTelemetryMs  = 0;
unsigned long lastReconnectMs  = 0;
bool lastMotionState           = false;

// ============================================================================
// 4. HÀM PHẢN HỒI TRẠNG THÁI (STATE ACK) & BÁO DANH (DISCOVERY)
// ============================================================================
void publishState(const char* stateTopic, bool isOn, const char* source) {
  if (!mqttClient.connected()) return;

  StaticJsonDocument<192> doc;
  doc["is_on"]  = isOn;
  doc["status"] = isOn ? "ON" : "OFF";
  doc["source"] = source;

  char payload[192];
  serializeJson(doc, payload);

  mqttClient.publish(stateTopic, payload, true);
  Serial.printf("🔄 [STATE ACK] %s -> %s\n", stateTopic, payload);
}

void publishDiscovery() {
  if (!mqttClient.connected()) return;

  // Báo danh Đèn
  {
    StaticJsonDocument<256> doc;
    doc["chip_id"]     = CHIP_ID;
    doc["name"]        = "Đèn thông minh";
    doc["device_type"] = "light";
    doc["mqtt_topic"]  = TOPIC_LIGHT_BASE;

    char payload[256];
    serializeJson(doc, payload);
    mqttClient.publish(TOPIC_DISCOVERY, payload, false);
  }

  // Báo danh Quạt
  {
    StaticJsonDocument<256> doc;
    doc["chip_id"]     = CHIP_ID;
    doc["name"]        = "Quạt thông minh";
    doc["device_type"] = "fan";
    doc["mqtt_topic"]  = TOPIC_FAN_BASE;

    char payload[256];
    serializeJson(doc, payload);
    mqttClient.publish(TOPIC_DISCOVERY, payload, false);
  }

  Serial.printf("📢 [DISCOVERY] Đã báo danh chip %s\n", CHIP_ID);
}

// ============================================================================
// 5. HÀM NHẬN LỆNH TỪ MQTT BROKER (WEB / AUTOMATION)
// ============================================================================
bool parseCommandOn(const String& msg) {
  String trimmed = msg;
  trimmed.trim();

  if (trimmed.startsWith("{")) {
    StaticJsonDocument<192> doc;
    if (deserializeJson(doc, trimmed) == DeserializationError::Ok) {
      if (doc.containsKey("is_on")) {
        return doc["is_on"].as<bool>();
      }
      if (doc.containsKey("status")) {
        String st = doc["status"].as<String>();
        st.toUpperCase();
        return (st == "ON" || st == "1" || st == "TRUE");
      }
    }
  }

  trimmed.toUpperCase();
  return (trimmed == "ON" || trimmed == "1" || trimmed == "TRUE");
}

void mqttCallback(char* topic, byte* payload, unsigned int length) {
  String topicStr(topic);
  String msg;
  msg.reserve(length);
  for (unsigned int i = 0; i < length; i++) {
    msg += (char)payload[i];
  }

  Serial.printf("📥 [MQTT CMD] %s -> %s\n", topic, msg.c_str());

  if (topicStr == TOPIC_DISCOVERY_REQ) {
    publishDiscovery();
    return;
  }

  if (topicStr == TOPIC_LIGHT_CTRL) {
    lightState = parseCommandOn(msg);
    digitalWrite(LED_LIGHT_PIN, lightState ? HIGH : LOW);
    publishState(TOPIC_LIGHT_STATE, lightState, "mqtt");
  } else if (topicStr == TOPIC_FAN_CTRL) {
    fanState = parseCommandOn(msg);
    digitalWrite(LED_FAN_PIN, fanState ? HIGH : LOW);
    publishState(TOPIC_FAN_STATE, fanState, "mqtt");
  }
}

// ============================================================================
// 6. KẾT NỐI WIFI & MQTT (CÓ LWT ONLINE/OFFLINE)
// ============================================================================
void connectWiFi() {
  if (WiFi.status() == WL_CONNECTED) return;

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.print("Đang kết nối WiFi");
  while (WiFi.status() != WL_CONNECTED) {
    delay(300);
    Serial.print(".");
  }
  Serial.printf("\n✅ Đã kết nối WiFi! IP: %s\n", WiFi.localIP().toString().c_str());
}

void ensureMqttConnected() {
  if (mqttClient.connected()) return;

  unsigned long now = millis();
  if (now - lastReconnectMs < 3000) return;
  lastReconnectMs = now;

  String clientId = String("esp32_") + CHIP_ID + "_" + String((uint32_t)esp_random(), HEX);

  // Đăng ký Last Will & Testament (LWT): tự gửi OFFLINE nếu mất kết nối đột ngột
  if (mqttClient.connect(clientId.c_str(), nullptr, nullptr, TOPIC_AVAIL, 1, true, "OFFLINE")) {
    Serial.println("✅ Đã kết nối MQTT Broker!");

    // Báo trạng thái ONLINE (retained)
    mqttClient.publish(TOPIC_AVAIL, "ONLINE", true);

    // Đăng ký nhận lệnh điều khiển & yêu cầu báo danh
    mqttClient.subscribe(TOPIC_LIGHT_CTRL, 1);
    mqttClient.subscribe(TOPIC_FAN_CTRL, 1);
    mqttClient.subscribe(TOPIC_DISCOVERY_REQ, 0);

    // Đồng bộ lại trạng thái hiện tại lên Backend & báo danh thiết bị
    publishState(TOPIC_LIGHT_STATE, lightState, "sync_reconnect");
    publishState(TOPIC_FAN_STATE, fanState, "sync_reconnect");
    publishDiscovery();
  } else {
    Serial.printf("❌ Kết nối MQTT thất bại (rc=%d), thử lại sau 3s...\n", mqttClient.state());
  }
}

// ============================================================================
// 7. ĐỌC NÚT NHẤN VẬT LÝ & CẢM BIẾN MÔI TRƯỜNG
// ============================================================================
void handlePhysicalButtons() {
  unsigned long now = millis();

  // --- Nút nhấn Đèn (GPIO 12) ---
  bool readingLight = digitalRead(BTN_LIGHT_PIN);
  if (readingLight != lastReadingLight) {
    lastDebounceLightMs = now;
  }
  if ((now - lastDebounceLightMs) > DEBOUNCE_DELAY_MS) {
    if (readingLight != stableBtnLight) {
      stableBtnLight = readingLight;
      if (stableBtnLight == LOW) {
        lightState = !lightState;
        digitalWrite(LED_LIGHT_PIN, lightState ? HIGH : LOW);
        Serial.printf("🔘 [BUTTON] Đèn -> %s\n", lightState ? "ON" : "OFF");
        publishState(TOPIC_LIGHT_STATE, lightState, "button");
      }
    }
  }
  lastReadingLight = readingLight;

  // --- Nút nhấn Quạt (GPIO 14) ---
  bool readingFan = digitalRead(BTN_FAN_PIN);
  if (readingFan != lastReadingFan) {
    lastDebounceFanMs = now;
  }
  if ((now - lastDebounceFanMs) > DEBOUNCE_DELAY_MS) {
    if (readingFan != stableBtnFan) {
      stableBtnFan = readingFan;
      if (stableBtnFan == LOW) {
        fanState = !fanState;
        digitalWrite(LED_FAN_PIN, fanState ? HIGH : LOW);
        Serial.printf("🔘 [BUTTON] Quạt -> %s\n", fanState ? "ON" : "OFF");
        publishState(TOPIC_FAN_STATE, fanState, "button");
      }
    }
  }
  lastReadingFan = readingFan;
}

void publishTelemetry(bool motionDetected) {
  if (!mqttClient.connected()) return;

  float temp = dht.readTemperature();
  float hum  = dht.readHumidity();
  if (isnan(temp)) temp = 25.0;
  if (isnan(hum))  hum  = 60.0;

  // Trên Wokwi photoresistor: càng sáng thì giá trị ADC càng thấp
  int rawLdr = analogRead(LDR_PIN);
  int lux    = constrain(map(rawLdr, 4095, 0, 0, 1000), 0, 1000);

  StaticJsonDocument<256> doc;
  doc["temperature"] = round(temp * 10.0) / 10.0;
  doc["humidity"]    = round(hum * 10.0) / 10.0;
  doc["lux"]         = lux;
  doc["motion"]      = motionDetected;

  char payload[256];
  serializeJson(doc, payload);
  mqttClient.publish(TOPIC_TELEMETRY, payload, false);
}

// ============================================================================
// 8. SETUP & LOOP CHÍNH
// ============================================================================
void setup() {
  Serial.begin(115200);

  pinMode(LED_LIGHT_PIN, OUTPUT);
  pinMode(LED_FAN_PIN, OUTPUT);
  digitalWrite(LED_LIGHT_PIN, LOW);
  digitalWrite(LED_FAN_PIN, LOW);

  pinMode(BTN_LIGHT_PIN, INPUT_PULLUP);
  pinMode(BTN_FAN_PIN, INPUT_PULLUP);
  pinMode(PIR_PIN, INPUT);
  pinMode(LDR_PIN, INPUT);

  dht.begin();

  Serial.println("====================================================");
  Serial.printf("ChipID : %s\n", CHIP_ID);
  Serial.printf("Topic light : %s\n", TOPIC_LIGHT_BASE);
  Serial.printf("Topic fan   : %s\n", TOPIC_FAN_BASE);
  Serial.printf("Topic sensor: %s\n", TOPIC_TELEMETRY);
  Serial.println("====================================================");

  connectWiFi();

  mqttClient.setServer(MQTT_BROKER, MQTT_PORT);
  mqttClient.setBufferSize(512); // Tăng buffer để gửi trọn gói JSON Discovery/Telemetry
  mqttClient.setCallback(mqttCallback);
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) {
    connectWiFi();
  }

  ensureMqttConnected();
  mqttClient.loop();

  // 1. Luôn quét nút nhấn tức thì (không bị delay chặn)
  handlePhysicalButtons();

  // 2. Đọc PIR liên tục để phản ứng ngay khi phát hiện chuyển động
  bool currentMotion = (digitalRead(PIR_PIN) == HIGH);
  bool motionRising  = (currentMotion && !lastMotionState);
  lastMotionState    = currentMotion;

  // 3. Gửi telemetry định kỳ mỗi 3 giây hoặc ngay lập tức khi có chuyển động mới
  unsigned long now = millis();
  if (motionRising || (now - lastTelemetryMs >= 3000)) {
    lastTelemetryMs = now;
    publishTelemetry(currentMotion);
  }
}