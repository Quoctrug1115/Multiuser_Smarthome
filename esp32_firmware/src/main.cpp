#include <WiFi.h>
#include <PubSubClient.h>
#include <DHT.h>

#define DHTPIN 15
#define DHTTYPE DHT22
#define LED_PIN 2

const char* ssid = "Wokwi-GUEST"; // Mạng Wi-Fi mặc định của Wokwi
const char* password = "";
const char* mqtt_server = "192.168.1.6"; // Thay bằng IP LAN máy tính chạy Docker Mosquitto
const int mqtt_port = 1883;

WiFiClient espClient;
PubSubClient client(espClient);
DHT dht(DHTPIN, DHTTYPE);

void setup_wifi() {
  delay(10);
  Serial.println("Connecting to WiFi...");
  WiFi.begin(ssid, password);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("\nWiFi connected! IP address: ");
  Serial.println(WiFi.localIP());
}

void callback(char* topic, byte* payload, unsigned int length) {
  String message;
  for (int i = 0; i < length; i++) {
    message += (char)payload[i];
  }
  Serial.printf("Message arrived [%s]: %s\n", topic, message.c_str());
  
  if (String(topic) == "smarthome/commands/led") {
    if (message == "ON") digitalWrite(LED_PIN, HIGH);
    else if (message == "OFF") digitalWrite(LED_PIN, LOW);
  }
}

void reconnect() {
  while (!client.connected()) {
    Serial.print("Attempting MQTT connection...");
    if (client.connect("ESP32_Simulated_Client")) {
      Serial.println("connected");
      client.subscribe("smarthome/commands/led");
    } else {
      Serial.print("failed, rc=");
      Serial.print(client.state());
      Serial.println(" try again in 5 seconds");
      delay(5000);
    }
  }
}

void setup() {
  Serial.begin(115200);
  pinMode(LED_PIN, OUTPUT);
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

  static unsigned long lastMsg = 0;
  unsigned long now = millis();
  if (now - lastMsg > 5000) { // Gửi dữ liệu mỗi 5s
    lastMsg = now;
    float h = dht.readHumidity();
    float t = dht.readTemperature();

    if (!isnan(h) && !isnan(t)) {
      String payload = "{\"temperature\":" + String(t) + ",\"humidity\":" + String(h) + "}";
      client.publish("smarthome/sensors/dht22", payload.c_str());
      Serial.println("Published: " + payload);
    }
  }
}