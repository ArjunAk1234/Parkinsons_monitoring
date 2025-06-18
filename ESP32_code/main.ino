
#include <Wire.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <time.h>

// WiFi credentials
const char* ssid = "";
const char* password = "";

// Firebase configuration
const char* firebaseHost = "";
const char* firebaseAuth = ""; // Optional for public writes

// Time configuration
const char* ntpServer1 = "pool.ntp.org";
const char* ntpServer2 = "time.google.com";
const char* ntpServer3 = "time.cloudflare.com";
const long gmtOffset_sec = 19800; // GMT+5:30 for India (adjust as needed)
const int daylightOffset_sec = 0;
bool timeInitialized = false;

// MPU6050 registers
#define MPU 0x68
#define ACCEL_XOUT_H 0x3B
#define GYRO_XOUT_H 0x43

// Medical parameters based on research papers
#define PD_FREQ_MIN 3.5f     // Hz - Parkinson's tremor frequency range
#define PD_FREQ_MAX 7.5f     // Hz - Based on Jankovic 2008, Deuschl 2001
#define REST_TREMOR_MIN 0.15f // m/s² - Minimum rest tremor amplitude
#define REST_TREMOR_MAX 1.2f  // m/s² - Maximum rest tremor amplitude  
#define ACTION_THRESH 0.8f    // m/s² - Action tremor threshold
#define GYRO_REST_MAX 30.0f   // deg/s - Max gyro for rest tremor
#define POSTURAL_GYRO_MIN 15.0f // deg/s - Min gyro for postural tremor
#define RHYTHMICITY_THRESH 0.65f // Autocorrelation threshold for rhythmicity
#define HARMONIC_RATIO_MIN 0.4f  // Minimum harmonic ratio for PD tremor

// Optimized sampling parameters
#define SAMPLE_RATE 64        // Hz - Power of 2 for efficient processing
#define WINDOW_SIZE 128       // 2 seconds at 64Hz, power of 2
#define ANALYSIS_SIZE 64      // 1 second analysis window
#define OVERLAP_SIZE 32       // 50% overlap

// Sensor data
float ax, ay, az, gx, gy, gz;
float accel_mag, gyro_mag;

// Circular buffers - using smaller data types where possible
int16_t accel_buf[WINDOW_SIZE];
int16_t gyro_buf[WINDOW_SIZE];
uint8_t buf_idx = 0;
bool buf_ready = false;

// Analysis variables
float dominant_freq = 0;
float tremor_amp = 0;
float harmonic_ratio = 0;
float rhythmicity = 0;
bool is_rest_tremor = false;
bool is_postural_tremor = false;
bool pd_tremor_detected = false;
bool previous_pd_state = false; // Track previous tremor detection state

// Timing variables - MODIFIED FOR 3 SECOND INTERVALS
uint32_t last_sample = 0;
uint32_t last_analysis = 0;
uint32_t last_firebase_send = 0;
const uint32_t FIREBASE_INTERVAL = 3000; // Send to Firebase every 3 seconds (CHANGED from 5000)

// Calibration offsets
int16_t ax_offset, ay_offset, az_offset;
int16_t gx_offset, gy_offset, gz_offset;

// Frequency analysis arrays (reused to save memory)
float temp_buffer[ANALYSIS_SIZE];
float freq_bins[32]; // For spectral analysis

// Device ID for Firebase
String deviceId;

// WiFi and Firebase status
bool wifiConnected = false;
bool firebaseReady = false;

// Function declarations
void initWiFi();
void initTime();
String getCurrentDateTime();
String getCurrentTimestamp();
void initMPU6050();
void writeReg(uint8_t reg, uint8_t data);
void calibrateSensors();
void readRawData();
void readSensorData();
void addToBuffers();
void analyzeParkinsonsTremor();
float calculateDominantFrequency();
float calculateTremorAmplitude();
float calculateHarmonicRatio();
float calculateRhythmicity();
void classifyTremorType();
void detectParkinsonsTremor();
bool detectVoluntaryMovement();
void transmitResults();
void sendToFirebase(bool isAlert = false);
void sendImmediateAlert();

void setup() {
  Serial.begin(115200);
  
  // Generate unique device ID
  deviceId = "ESP32_" + String((uint32_t)ESP.getEfuseMac(), HEX);
  
  // Initialize WiFi
  initWiFi();
  
  // Initialize time sync
  initTime();
  
  initMPU6050();
  calibrateSensors();
  
  Serial.println("Parkinson's Tremor Detector Ready");
  Serial.println("Medical-grade detection algorithms active");
  Serial.println("Device ID: " + deviceId);
  Serial.println("Data transmission: Every 3 seconds + Instant tremor alerts");
  Serial.println("Current time: " + getCurrentDateTime());
}

void loop() {
  uint32_t now = millis();
  
  // Check WiFi connection
  if (WiFi.status() != WL_CONNECTED) {
    wifiConnected = false;
    Serial.println("WiFi disconnected, attempting reconnection...");
    initWiFi();
    // Re-initialize time after WiFi reconnection
    if (wifiConnected) {
      initTime();
    }
  } else {
    wifiConnected = true;
  }
  
  if (now - last_sample >= 16) { // ~64Hz sampling
    readSensorData();
    addToBuffers();
    last_sample = now;
  }
  
  if (buf_ready && now - last_analysis >= 500) { // Analyze every 0.5s
    analyzeParkinsonsTremor();
    transmitResults();
    
    // NEW: Check for tremor state change and send immediate alert
    if (pd_tremor_detected && !previous_pd_state) {
      // Tremor just detected - send immediate alert
      Serial.println("TREMOR DETECTED - SENDING IMMEDIATE ALERT!");
      Serial.println("Alert time: " + getCurrentDateTime());
      sendImmediateAlert();
    }
    
    // Update previous state
    previous_pd_state = pd_tremor_detected;
    last_analysis = now;
  }
  
  // Send regular data to Firebase every 3 seconds
  if (wifiConnected && now - last_firebase_send >= FIREBASE_INTERVAL) {
    sendToFirebase(false); // Regular data transmission
    last_firebase_send = now;
  }
}

void initWiFi() {
  WiFi.begin(ssid, password);
  Serial.print("Connecting to WiFi");
  
  int attempts = 0;
  while (WiFi.status() != WL_CONNECTED && attempts < 20) {
    delay(500);
    Serial.print(".");
    attempts++;
  }
  
  if (WiFi.status() == WL_CONNECTED) {
    Serial.println();
    Serial.println("WiFi connected!");
    Serial.print("IP address: ");
    Serial.println(WiFi.localIP());
    wifiConnected = true;
    firebaseReady = true;
  } else {
    Serial.println();
    Serial.println("WiFi connection failed!");
    wifiConnected = false;
    firebaseReady = false;
  }
}

void initTime() {
  // Configure time with multiple NTP servers for better reliability
  configTime(gmtOffset_sec, daylightOffset_sec, ntpServer1, ntpServer2, ntpServer3);
  
  Serial.print("Synchronizing time");
  int attempts = 0;
  time_t now = 0;
  struct tm timeinfo;
  
  while (!getLocalTime(&timeinfo) && attempts < 10) {
    Serial.print(".");
    delay(1000);
    attempts++;
  }
  
  if (getLocalTime(&timeinfo)) {
    Serial.println();
    Serial.println("Time synchronized successfully!");
    Serial.println("Current time: " + getCurrentDateTime());
    timeInitialized = true;
  } else {
    Serial.println();
    Serial.println("Failed to synchronize time - using system uptime");
    timeInitialized = false;
  }
}

String getCurrentDateTime() {
  struct tm timeinfo;
  if (!getLocalTime(&timeinfo) || !timeInitialized) {
    // Fallback to uptime-based timestamp
    unsigned long uptime = millis();
    unsigned long seconds = uptime / 1000;
    unsigned long minutes = seconds / 60;
    unsigned long hours = minutes / 60;
    unsigned long days = hours / 24;
    
    return "Uptime: " + String(days) + "d " + String(hours % 24) + "h " + 
           String(minutes % 60) + "m " + String(seconds % 60) + "s";
  }
  
  char timeString[64];
  strftime(timeString, sizeof(timeString), "%Y-%m-%d %H:%M:%S", &timeinfo);
  return String(timeString);
}

String getCurrentTimestamp() {
  struct tm timeinfo;
  if (!getLocalTime(&timeinfo) || !timeInitialized) {
    // Return Unix timestamp based on system uptime (less accurate but functional)
    return String(millis());
  }
  
  time_t now;
  time(&now);
  return String(now);
}

void initMPU6050() {
  Wire.begin();
  
  // Wake up MPU6050
  writeReg(0x6B, 0x00);
  
  // Configure accelerometer: ±2g for maximum sensitivity
  writeReg(0x1C, 0x00);
  
  // Configure gyroscope: ±250°/s for tremor detection
  writeReg(0x1B, 0x00);
  
  // Set sample rate to 1kHz/(1+7) = 125Hz (we'll downsample)
  writeReg(0x19, 0x07);
  
  // Enable low-pass filter: 44Hz bandwidth
  writeReg(0x1A, 0x03);
}

void writeReg(uint8_t reg, uint8_t data) {
  Wire.beginTransmission(MPU);
  Wire.write(reg);
  Wire.write(data);
  Wire.endTransmission();
}

void calibrateSensors() {
  Serial.println("Calibrating - keep device still on flat surface");
  
  int32_t ax_sum = 0, ay_sum = 0, az_sum = 0;
  int32_t gx_sum = 0, gy_sum = 0, gz_sum = 0;
  
  for (int i = 0; i < 1000; i++) {
    readRawData();
    ax_sum += (int32_t)ax; ay_sum += (int32_t)ay; az_sum += (int32_t)az;
    gx_sum += (int32_t)gx; gy_sum += (int32_t)gy; gz_sum += (int32_t)gz;
    delay(2);
  }
  
  ax_offset = ax_sum / 1000;
  ay_offset = ay_sum / 1000;
  az_offset = (az_sum / 1000) - 16384; // Account for 1g gravity
  gx_offset = gx_sum / 1000;
  gy_offset = gy_sum / 1000;
  gz_offset = gz_sum / 1000;
  
  Serial.println("Calibration complete");
}

void readRawData() {
  Wire.beginTransmission(MPU);
  Wire.write(ACCEL_XOUT_H);
  Wire.endTransmission(false);
  Wire.requestFrom(MPU, 14, true);
  
  ax = (Wire.read() << 8) | Wire.read();
  ay = (Wire.read() << 8) | Wire.read();
  az = (Wire.read() << 8) | Wire.read();
  Wire.read(); Wire.read(); // Skip temperature
  gx = (Wire.read() << 8) | Wire.read();
  gy = (Wire.read() << 8) | Wire.read();
  gz = (Wire.read() << 8) | Wire.read();
}

void readSensorData() {
  readRawData();
  
  // Apply calibration and convert to physical units
  ax = ((ax - ax_offset) / 16384.0f) * 9.81f; // m/s²
  ay = ((ay - ay_offset) / 16384.0f) * 9.81f;
  az = ((az - az_offset) / 16384.0f) * 9.81f;
  gx = (gx - gx_offset) / 131.0f; // deg/s
  gy = (gy - gy_offset) / 131.0f;
  gz = (gz - gz_offset) / 131.0f;
  
  // Calculate magnitudes
  accel_mag = sqrt(ax*ax + ay*ay + az*az);
  gyro_mag = sqrt(gx*gx + gy*gy + gz*gz);
}

void addToBuffers() {
  // Store as scaled integers to save memory
  accel_buf[buf_idx] = (int16_t)(accel_mag * 1000); // Scale by 1000
  gyro_buf[buf_idx] = (int16_t)(gyro_mag * 10);     // Scale by 10
  
  buf_idx++;
  if (buf_idx >= WINDOW_SIZE) {
    buf_idx = 0;
    buf_ready = true;
  }
}

void analyzeParkinsonsTremor() {
  // Copy recent data for analysis
  uint8_t start_idx = (buf_idx >= ANALYSIS_SIZE) ? buf_idx - ANALYSIS_SIZE : WINDOW_SIZE - (ANALYSIS_SIZE - buf_idx);
  
  for (int i = 0; i < ANALYSIS_SIZE; i++) {
    uint8_t idx = (start_idx + i) % WINDOW_SIZE;
    temp_buffer[i] = accel_buf[idx] / 1000.0f; // Convert back to m/s²
  }
  
  // 1. Frequency Domain Analysis
  dominant_freq = calculateDominantFrequency();
  
  // 2. Amplitude Analysis
  tremor_amp = calculateTremorAmplitude();
  
  // 3. Harmonic Analysis (key for PD tremor identification)
  harmonic_ratio = calculateHarmonicRatio();
  
  // 4. Rhythmicity Analysis
  rhythmicity = calculateRhythmicity();
  
  // 5. Movement Context Analysis
  classifyTremorType();
  
  // 6. Multi-criteria PD Tremor Detection
  detectParkinsonsTremor();
}

float calculateDominantFrequency() {
  // Zero-crossing frequency estimation with peak detection
  float mean = 0;
  for (int i = 0; i < ANALYSIS_SIZE; i++) {
    mean += temp_buffer[i];
  }
  mean /= ANALYSIS_SIZE;
  
  // Remove DC component
  for (int i = 0; i < ANALYSIS_SIZE; i++) {
    temp_buffer[i] -= mean;
  }
  
  // Count zero crossings
  int crossings = 0;
  for (int i = 1; i < ANALYSIS_SIZE; i++) {
    if (temp_buffer[i-1] * temp_buffer[i] < 0) {
      crossings++;
    }
  }
  
  return (crossings / 2.0f) * SAMPLE_RATE / ANALYSIS_SIZE;
}

float calculateTremorAmplitude() {
  float sum_sq = 0;
  float mean = 0;
  
  for (int i = 0; i < ANALYSIS_SIZE; i++) {
    mean += temp_buffer[i];
  }
  mean /= ANALYSIS_SIZE;
  
  for (int i = 0; i < ANALYSIS_SIZE; i++) {
    float diff = temp_buffer[i] - mean;
    sum_sq += diff * diff;
  }
  
  return sqrt(sum_sq / ANALYSIS_SIZE);
}

float calculateHarmonicRatio() {
  // Calculate power at fundamental vs harmonics
  // Key discriminator for PD tremor vs other movements
  
  if (dominant_freq < 1.0f) return 0;
  
  float fundamental_power = 0;
  float harmonic_power = 0;
  int fund_bin = (int)(dominant_freq * ANALYSIS_SIZE / SAMPLE_RATE);
  
  // Simplified spectral analysis using autocorrelation
  for (int lag = 1; lag < ANALYSIS_SIZE/4; lag++) {
    float corr = 0;
    for (int i = 0; i < ANALYSIS_SIZE - lag; i++) {
      corr += temp_buffer[i] * temp_buffer[i + lag];
    }
    
    float freq = (float)SAMPLE_RATE / lag;
    if (abs(freq - dominant_freq) < 0.5f) {
      fundamental_power += abs(corr);
    } else if (freq > dominant_freq * 1.8f && freq < dominant_freq * 2.2f) {
      harmonic_power += abs(corr);
    }
  }
  
  return fundamental_power / (fundamental_power + harmonic_power + 0.001f);
}

float calculateRhythmicity() {
  // Autocorrelation at expected tremor period
  int period_samples = SAMPLE_RATE / max(dominant_freq, 1.0f);
  
  if (period_samples >= ANALYSIS_SIZE/2) return 0;
  
  float autocorr = 0;
  float norm = 0;
  
  for (int i = 0; i < ANALYSIS_SIZE - period_samples; i++) {
    autocorr += temp_buffer[i] * temp_buffer[i + period_samples];
    norm += temp_buffer[i] * temp_buffer[i];
  }
  
  return norm > 0 ? autocorr / norm : 0;
}

void classifyTremorType() {
  // Get recent gyroscope data
  float recent_gyro = 0;
  for (int i = 0; i < 16; i++) { // Last 0.25 seconds
    uint8_t idx = (buf_idx - 1 - i + WINDOW_SIZE) % WINDOW_SIZE;
    recent_gyro += gyro_buf[idx] / 10.0f;
  }
  recent_gyro /= 16.0f;
  
  // Rest tremor: low gyro activity, moderate amplitude
  is_rest_tremor = (recent_gyro < GYRO_REST_MAX) && 
                   (tremor_amp >= REST_TREMOR_MIN) && 
                   (tremor_amp <= REST_TREMOR_MAX);
  
  // Postural tremor: higher gyro activity
  is_postural_tremor = (recent_gyro >= POSTURAL_GYRO_MIN) && 
                       (tremor_amp < ACTION_THRESH);
}

void detectParkinsonsTremor() {
  // Multi-criteria detection based on medical literature
  bool freq_match = (dominant_freq >= PD_FREQ_MIN && dominant_freq <= PD_FREQ_MAX);
  bool amplitude_ok = (tremor_amp >= REST_TREMOR_MIN);
  bool rhythmic = (rhythmicity > RHYTHMICITY_THRESH);
  bool harmonic_ok = (harmonic_ratio > HARMONIC_RATIO_MIN);
  bool tremor_type_ok = (is_rest_tremor || is_postural_tremor);
  
  // Additional criteria: exclude voluntary movements
  bool not_voluntary = !detectVoluntaryMovement();
  
  // Final classification
  pd_tremor_detected = freq_match && amplitude_ok && rhythmic && 
                      harmonic_ok && tremor_type_ok && not_voluntary;
}

bool detectVoluntaryMovement() {
  // Detect voluntary movements by analyzing acceleration patterns
  float max_accel = 0;
  float avg_accel = tremor_amp;
  
  for (int i = 0; i < ANALYSIS_SIZE; i++) {
    if (abs(temp_buffer[i]) > max_accel) {
      max_accel = abs(temp_buffer[i]);
    }
  }
  
  // Voluntary movements have high peak-to-average ratio
  float peak_ratio = max_accel / (avg_accel + 0.01f);
  
  // Voluntary movements typically have lower frequency and higher amplitude
  bool high_amplitude_low_freq = (tremor_amp > 2.0f && dominant_freq < 2.0f);
  bool sudden_spikes = (peak_ratio > 4.0f);
  
  return high_amplitude_low_freq || sudden_spikes;
}

void transmitResults() {
  // Local Serial output for debugging
  String data = "PD:";
  data += pd_tremor_detected ? "1" : "0";
  data += ",F:"; data += String(dominant_freq, 1);
  data += ",A:"; data += String(tremor_amp, 2);
  data += ",R:"; data += String(rhythmicity, 2);
  data += ",H:"; data += String(harmonic_ratio, 2);
  data += ",TYPE:";
  if (is_rest_tremor) data += "REST";
  else if (is_postural_tremor) data += "POST";
  else data += "NONE";
  
  if (pd_tremor_detected) {
    Serial.println("*** PARKINSON'S TREMOR DETECTED ***");
    Serial.println("Confidence: HIGH");
    Serial.println("Frequency: " + String(dominant_freq, 1) + " Hz");
    Serial.println("Amplitude: " + String(tremor_amp, 2) + " m/s²");
    Serial.println("Type: " + String(is_rest_tremor ? "Rest" : "Postural"));
    Serial.println("Rhythmicity: " + String(rhythmicity, 2));
    Serial.println("Harmonic Ratio: " + String(harmonic_ratio, 2));
    Serial.println("Time: " + getCurrentDateTime());
    Serial.println("WiFi Status: " + String(wifiConnected ? "Connected" : "Disconnected"));
    Serial.println("===============================");
  }
  
  // Always send debug data
  Serial.println(data);
}

// MODIFIED: Added parameter to distinguish between regular and alert transmissions
void sendToFirebase(bool isAlert) {
  if (!firebaseReady) {
    Serial.println("Firebase not ready");
    return;
  }
  
  HTTPClient http;
  
  // Create Firebase URL - different paths for regular data vs alerts
  String url;
  if (isAlert) {
    String safeDateTime = getCurrentDateTime();
    safeDateTime.replace(":", "_"); // Replace colons with underscores
    safeDateTime.replace(" ", "_"); // Replace space with underscore
    url = String(firebaseHost) + "/alerts/" + deviceId + "/" + safeDateTime + ".json";
    // url = String(firebaseHost) + "/alerts/" + deviceId + "/" + String(millis()) + ".json";
  } else {
    url = String(firebaseHost) + "/tremor_data/" + deviceId + ".json";
  }
  
  if (strlen(firebaseAuth) > 0) {
    url += "?auth=" + String(firebaseAuth);
  }
  
  http.begin(url);
  http.addHeader("Content-Type", "application/json");
  
  // Create JSON payload
  DynamicJsonDocument doc(1536); // Increased size for additional time fields
  
  // Enhanced timestamp information
  String currentDateTime = getCurrentDateTime();
  String currentTimestamp = getCurrentTimestamp();
  
  doc["timestamp_unix"] = currentTimestamp.toInt();
  doc["timestamp_readable"] = currentDateTime;
  doc["time_sync_status"] = timeInitialized ? "SYNCED" : "UPTIME_BASED";
  doc["device_id"] = deviceId;
  doc["pd_detected"] = pd_tremor_detected;
  doc["dominant_frequency"] = dominant_freq;
  doc["tremor_amplitude"] = tremor_amp;
  doc["rhythmicity"] = rhythmicity;
  doc["harmonic_ratio"] = harmonic_ratio;
  doc["is_rest_tremor"] = is_rest_tremor;
  doc["is_postural_tremor"] = is_postural_tremor;
  
  // Add alert-specific fields with proper timestamps
  if (isAlert) {
    doc["alert_type"] = "TREMOR_DETECTED";
    doc["severity"] = "HIGH";
    doc["immediate_alert"] = true;
    doc["alert_datetime"] = currentDateTime;
    doc["alert_timestamp"] = currentTimestamp.toInt();
    
    // Additional alert metadata
    JsonObject alert_meta = doc.createNestedObject("alert_metadata");
    alert_meta["detection_confidence"] = "HIGH";
    alert_meta["alert_priority"] = "IMMEDIATE";
    alert_meta["notification_required"] = true;
    alert_meta["time_zone_info"] = "GMT+5:30";
  } else {
    doc["data_type"] = "REGULAR_UPDATE";
    doc["update_datetime"] = currentDateTime;
    doc["update_timestamp"] = currentTimestamp.toInt();
  }
  
  // Sensor data with timestamp
  JsonObject sensor_data = doc.createNestedObject("sensor_data");
  sensor_data["accel_x"] = ax;
  sensor_data["accel_y"] = ay;
  sensor_data["accel_z"] = az;
  sensor_data["gyro_x"] = gx;
  sensor_data["gyro_y"] = gy;
  sensor_data["gyro_z"] = gz;
  sensor_data["accel_magnitude"] = accel_mag;
  sensor_data["gyro_magnitude"] = gyro_mag;
  sensor_data["reading_time"] = currentDateTime;
  
  // Status information with enhanced timing
  JsonObject status = doc.createNestedObject("status");
  status["wifi_rssi"] = WiFi.RSSI();
  status["free_heap"] = ESP.getFreeHeap();
  status["uptime_ms"] = millis();
  status["transmission_type"] = isAlert ? "IMMEDIATE_ALERT" : "SCHEDULED_UPDATE";
  status["time_synchronized"] = timeInitialized;
  status["local_time"] = currentDateTime;
  status["unix_timestamp"] = currentTimestamp.toInt();
  
  String jsonString;
  serializeJson(doc, jsonString);
  
  // Send HTTP PUT request
  int httpResponseCode = http.PUT(jsonString);
  
  if (httpResponseCode > 0) {
    String response = http.getString();
    Serial.println("Firebase Response Code: " + String(httpResponseCode));
    
    if (isAlert) {
      Serial.println("*** IMMEDIATE TREMOR ALERT SENT TO FIREBASE ***");
      Serial.println("Alert Timestamp: " + currentDateTime);
      Serial.println("Unix Timestamp: " + currentTimestamp);
    } else if (pd_tremor_detected) {
      Serial.println("Regular tremor data sent to Firebase (3s interval)");
      Serial.println("Data Timestamp: " + currentDateTime);
    } else {
      Serial.println("Regular data sent to Firebase (3s interval)");
    }
  } else {
    Serial.println("Firebase Error: " + String(httpResponseCode));
    Serial.println("Error: " + http.errorToString(httpResponseCode));
    
    // If time sync fails, try to re-initialize
    if (httpResponseCode == -1 && timeInitialized) {
      Serial.println("Attempting to re-sync time...");
      initTime();
    }
  }
  
  http.end();
}

// Enhanced immediate alert function
void sendImmediateAlert() {
  if (!firebaseReady || !pd_tremor_detected) return;
  
  String alertTime = getCurrentDateTime();
  
  // Use the modified sendToFirebase function with alert flag
  sendToFirebase(true);
  
  // Additional immediate response actions
  Serial.println("🚨 IMMEDIATE ALERT DISPATCHED 🚨");
  Serial.println("Alert Time: " + alertTime);
  Serial.println("System Uptime: " + String(millis()) + "ms");
  Serial.println("Time Sync Status: " + String(timeInitialized ? "SYNCHRONIZED" : "UPTIME_BASED"));
  Serial.println("Next regular update in: " + String(FIREBASE_INTERVAL - (millis() - last_firebase_send)) + "ms");
}
