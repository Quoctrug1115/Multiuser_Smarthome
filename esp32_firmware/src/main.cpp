#include <WiFi.h>
#include <PubSubClient.h>
#include <DHT.h>
#include <ArduinoJson.h>

// --- Định cấu hình Chân cắm (Pin Mapping) ---
#define DHTPIN 15
#define DHTTYPE DHT22
#define LDR_PIN 34       // Chân Analog đọc cảm biến ánh sáng
#define PIR_PIN 13       // Chân Digital đọc cảm biến chuyển động
#define RELAY_LIGHT_PIN 2 // Điều khiển Đèn phòng khách (d1)
#define RELAY_FAN_PIN 4   // Điều khiển Quạt thông gió (d2)

// --- Mạng WiFi & Broker MQTT ---
const char* ssid = "Wokwi-GUEST";
const char* password = "";
const char* mqtt_server = "broker.emqx.io";
const int mqtt_port = 1883;

// --- Topics MQTT ---
String topic_telemetry     = "smarthome/sensors/dht22";
String topic_cmd_light     = "smarthome/devices/d1/command";
String topic_cmd_fan       = "smarthome/devices/d2/command";
String topic_state         = "smarthome/devices/state";

WiFiClient espClient;
PubSubClient client(espClient);
DHT dht(DHTPIN, DHTTYPE);

unsigned long lastMsg = 0;

void setup_wifi() {
  delay(10);
  Serial.println("\n[WiFi] Đang kết nối WiFi...");
  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid, password);

  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("\n[WiFi] Kết nối thành công! IP: " + WiFi.localIP().toString());
}

// Xử lý lệnh điều khiển từ Web Dashboard (Lắng nghe cho cả Đèn d1 và Quạt d2)
void callback(char* topic, byte* payload, unsigned int length) {
  String message;
  for (unsigned int i = 0; i < length; i++) {
    message += (char)payload[i];
  }
  String topicStr = String(topic);
  Serial.printf("📩 [MQTT RECV] Topic [%s]: %s\n", topic, message.c_str());

  StaticJsonDocument<200> doc;
  DeserializationError error = deserializeJson(doc, message);
  String powerState = (!error && doc.containsKey("power")) ? doc["power"].as<String>() : message;

  // Xử lý điều khiển Đèn (d1)
  if (topicStr == topic_cmd_light) {
    if (powerState == "ON") {
      digitalWrite(RELAY_LIGHT_PIN, HIGH);
      Serial.println(" -> ĐÈN PHÒNG KHÁCH (GPIO 2): BẬT");
    } else if (powerState == "OFF") {
      digitalWrite(RELAY_LIGHT_PIN, LOW);
      Serial.println(" -> ĐÈN PHÒNG KHÁCH (GPIO 2): TẮT");
    }
  }

  // Xử lý điều khiển Quạt (d2)
  if (topicStr == topic_cmd_fan) {
    if (powerState == "ON") {
      digitalWrite(RELAY_FAN_PIN, HIGH);
      Serial.println(" -> QUẠT THÔNG GIÓ (GPIO 4): BẬT");
    } else if (powerState == "OFF") {
      digitalWrite(RELAY_FAN_PIN, LOW);
      Serial.println(" -> QUẠT THÔNG GIÓ (GPIO 4): TẮT");
    }
  }
}

void reconnect() {
  while (!client.connected()) {
    Serial.print("[MQTT] Đang kết nối emqx.io...");
    String clientId = "ESP32_SmartHome_Full_" + String(random(0xffff), HEX);

    if (client.connect(clientId.c_str())) {
      Serial.println(" [THÀNH CÔNG]");
      client.subscribe(topic_cmd_light.c_str());
      client.subscribe(topic_cmd_fan.c_str());
      Serial.println("✅ Subscribed thành công các Topic điều khiển!");
    } else {
      Serial.printf(" Lỗi (rc=%d), thử lại sau 2s...\n", client.state());
      delay(2000);
    }
  }
}

void setup() {
  Serial.begin(115200);
  pinMode(RELAY_LIGHT_PIN, OUTPUT);
  pinMode(RELAY_FAN_PIN, OUTPUT);
  pinMode(PIR_PIN, INPUT);

  digitalWrite(RELAY_LIGHT_PIN, LOW);
  digitalWrite(RELAY_FAN_PIN, LOW);

  dht.begin();
  setup_wifi();

  client.setServer(mqtt_server, mqtt_port);
  client.setCallback(callback);
}

void loop() {
  if (!client.connected()) {
    reconnect();
  }
  client.loop();

  // Đọc dữ liệu từ toàn bộ cảm biến mỗi 3 giây
  unsigned long now = millis();
  if (now - lastMsg > 3000) {
    lastMsg = now;

    float temp = dht.readTemperature();
    float hum = dht.readHumidity();

    // Tính toán Lux giả lập từ cảm biến LDR (Chân 34)
    int ldrRaw = analogRead(LDR_PIN);
    int lux = map(ldrRaw, 0, 4095, 0, 1000); 

    // Đọc trạng thái cảm biến PIR (Chân 13)
    bool motion = digitalRead(PIR_PIN) == HIGH;

    if (!isnan(temp) && !isnan(hum)) {
      StaticJsonDocument<256> doc;
      doc["temperature"] = temp;
      doc["humidity"] = hum;
      doc["lux"] = lux;
      doc["motion"] = motion;
      doc["sensor_id"] = "esp32-main-hub";

      char buffer[256];
      serializeJson(doc, buffer);

      client.publish(topic_telemetry.c_str(), buffer);
      Serial.printf("📤 [MQTT PUB FULL] %s -> %s\n", topic_telemetry.c_str(), buffer);
    }
  }
}