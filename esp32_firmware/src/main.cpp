#include <Arduino.h>
#include <WiFi.h>
#include <PubSubClient.h>
#include <DHT.h>

// 1. Cấu hình WiFi mặc định của Wokwi
const char* ssid = "Wokwi-GUEST";
const char* password = "";

// 2. Cấu hình MQTT Broker (khớp với Backend Rust)
const char* mqtt_server = "broker.emqx.io";
const int mqtt_port = 1883;

// 3. Định nghĩa chân linh kiện khớp 100% với diagram.json
#define LED_LIGHT_PIN 2   // esp:D2 - Đèn vàng
#define LED_FAN_PIN   4   // esp:D4 - Quạt (LED xanh dương)
#define DHT_PIN       15  // esp:D15 - Cảm biến nhiệt độ/độ ẩm DHT22
#define LDR_PIN       36  // esp:VP - Cảm biến ánh sáng (Photoresistor AO)
#define PIR_PIN       13  // esp:D13 - Cảm biến chuyển động PIR
#define DHT_TYPE      DHT22

WiFiClient espClient;
PubSubClient client(espClient);
DHT dht(DHT_PIN, DHT_TYPE);

unsigned long lastSensorRead = 0;

void setup_wifi() {
  delay(10);
  Serial.print("Đang kết nối WiFi Wokwi");
  WiFi.begin(ssid, password);
  while (WiFi.status() != WL_CONNECTED) {
    delay(300);
    Serial.print(".");
  }
  Serial.println("\n✅ Đã kết nối WiFi!");
}

bool isTurnOnCommand(const String& msg) {
  String upper = msg;
  upper.toUpperCase();
  return upper.indexOf("ON") != -1 || upper.indexOf("TRUE") != -1 || upper == "1";
}

bool isTurnOffCommand(const String& msg) {
  String upper = msg;
  upper.toUpperCase();
  return upper.indexOf("OFF") != -1 || upper.indexOf("FALSE") != -1 || upper == "0";
}

// Nhận lệnh bật/tắt Đèn và Quạt từ Mobile/Backend gửi xuống
void callback(char* topic, byte* payload, unsigned int length) {
  String msg;
  for (unsigned int i = 0; i < length; i++) {
    msg += (char)payload[i];
  }
  String topicStr = String(topic);
  Serial.println("📩 Nhận lệnh [" + topicStr + "]: " + msg);

  // Điều khiển Đèn (GPIO 2)
  if (topicStr.indexOf("led_phong_khach") != -1) {
    if (isTurnOnCommand(msg)) {
      digitalWrite(LED_LIGHT_PIN, HIGH);
    } else if (isTurnOffCommand(msg)) {
      digitalWrite(LED_LIGHT_PIN, LOW);
    }
  }

  // Điều khiển Quạt (GPIO 4)
  if (topicStr.indexOf("quat_phong_khach") != -1) {
    if (isTurnOnCommand(msg)) {
      digitalWrite(LED_FAN_PIN, HIGH);
    } else if (isTurnOffCommand(msg)) {
      digitalWrite(LED_FAN_PIN, LOW);
    }
  }
  if (topicStr == "smarthome/discovery/request") {
  publishDiscovery(); // Tên hàm gửi JSON lên smarthome/discovery của bạn
  return;
}
}

void reconnect() {
  while (!client.connected()) {
    String clientId = "Wokwi_ESP32_" + String(random(0xffff), HEX);
    if (client.connect(clientId.c_str())) {
      Serial.println("✅ Đã kết nối MQTT Broker!");

      // Lắng nghe lệnh điều khiển Đèn và Quạt
      client.subscribe("smarthome/devices/led_phong_khach");
      client.subscribe("smarthome/devices/led_phong_khach/control");
      client.subscribe("smarthome/devices/quat_phong_khach");
      client.subscribe("smarthome/devices/quat_phong_khach/control");
      client.subscribe("smarthome/discovery/request");

      // Báo danh 3 thiết bị lên topic discovery để Mobile quét tự động
      const char* lightDiscovery =
          "{\"name\":\"Đèn Phòng Khách (Wokwi)\",\"device_type\":\"light\",\"mqtt_topic\":\"smarthome/devices/led_phong_khach\"}";
      client.publish("smarthome/discovery", lightDiscovery, true);

      const char* fanDiscovery =
          "{\"name\":\"Quạt Phòng Khách (Wokwi)\",\"device_type\":\"fan\",\"mqtt_topic\":\"smarthome/devices/quat_phong_khach\"}";
      client.publish("smarthome/discovery", fanDiscovery, true);

      const char* sensorDiscovery =
          "{\"name\":\"Cảm Biến Môi Trường (Wokwi)\",\"device_type\":\"sensor\",\"mqtt_topic\":\"smarthome/sensors/dht22\"}";
      client.publish("smarthome/discovery", sensorDiscovery, true);
    } else {
      delay(2000);
    }
  }
}

void setup() {
  Serial.begin(115200);
  pinMode(LED_LIGHT_PIN, OUTPUT);
  pinMode(LED_FAN_PIN, OUTPUT);
  pinMode(PIR_PIN, INPUT);
  pinMode(LDR_PIN, INPUT);

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

  // Đọc & gửi dữ liệu DHT22 + Ánh sáng (Lux) + Chuyển động (PIR) mỗi 5 giây
  if (millis() - lastSensorRead > 5000) {
    lastSensorRead = millis();

    float t = dht.readTemperature();
    float h = dht.readHumidity();
    int rawLdr = analogRead(LDR_PIN); // Giá trị 0 -> 4095
    int lux = map(rawLdr, 4095, 0, 0, 1000); // Quy đổi sang mức Lux (0 - 1000)
    bool motion = digitalRead(PIR_PIN) == HIGH;

    if (!isnan(t) && !isnan(h)) {
      String sensorJson = "{\"temperature\":" + String(t, 1) +
                          ",\"humidity\":" + String(h, 1) +
                          ",\"lux\":" + String(lux) +
                          ",\"motion\":" + String(motion ? "true" : "false") +
                          ",\"sensor_id\":\"esp32_wokwi_01\"}";
      client.publish("smarthome/sensors/dht22", sensorJson.c_str());
      Serial.println("📤 Gửi Telemetry: " + sensorJson);
    }
  }
}