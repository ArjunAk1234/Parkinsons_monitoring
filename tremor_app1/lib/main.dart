import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:workmanager/workmanager.dart';
void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Parkinson\'s Tremor Monitor',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        fontFamily: 'Roboto',
        cardTheme: CardThemeData(
          elevation: 8,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        // Ensure Material Icons are properly loaded
        useMaterial3: true,
      ),
      home: TremorMonitorScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class TremorMonitorScreen extends StatefulWidget {
  const TremorMonitorScreen({super.key});

  @override
  _TremorMonitorScreenState createState() => _TremorMonitorScreenState();
}

class _TremorMonitorScreenState extends State<TremorMonitorScreen> with TickerProviderStateMixin {
  // Firebase configuration
  final String firebaseHost = "";
  final String deviceId = "";
   
  // Timers
  Timer? alertCheckTimer;
  Timer? regularDataTimer;
  Timer? alertExpiryTimer;
  
  // Animation controllers
  late AnimationController _pulseController;
  late AnimationController _rotationController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _rotationAnimation;
  
  // Connection state
  bool isFirebaseConnected = false;
  bool hasInitialized = false;
  String connectionStatus = "Initializing...";
  
  // Data variables
  bool isHighTremor = false;
  DateTime? lastHighTremorTime;
  DateTime? lastDataUpdateTime;
  
  // Regular tremor data (always updated from regular data stream)
  double regularDominantFrequency = 0.0;
  double regularTremorAmplitude = 0.0;
  double regularRhythmicity = 0.0;
  double regularHarmonicRatio = 0.0;
  bool regularIsRestTremor = false;
  bool regularIsPosturalTremor = false;
  String regularTremorType = "NONE";
  String regularLastUpdateTime = "";
  
  // Alert tremor data (from high tremor alerts)
  double alertDominantFrequency = 0.0;
  double alertTremorAmplitude = 0.0;
  double alertRhythmicity = 0.0;
  double alertHarmonicRatio = 0.0;
  bool alertIsRestTremor = false;
  bool alertIsPosturalTremor = false;
  String alertTremorType = "NONE";
  
  // Alert data
  String alertTimestamp = "";
  String currentAlertKey = "";
  String lastProcessedAlertKey = "";
  bool hasNewAlert = false;
  int currentAlertUnixTime = 0;
  
  // Alert history for better tracking
  Map<String, dynamic> alertHistory = {};
  
  // Status
  int alertCheckCount = 0;
  int dataUpdateCount = 0;
  String alertTimeRemaining = "";
  // Add these after your existing variables
  FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  bool notificationsInitialized = false;
  bool backgroundServiceRunning = false;

  @override
void initState() {
  super.initState();
  
  // Initialize animation controllers
  _pulseController = AnimationController(
    duration: Duration(milliseconds: 1000),
    vsync: this,
  );
  _rotationController = AnimationController(
    duration: Duration(seconds: 2),
    vsync: this,
  );
  
  _pulseAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
    CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
  );
  _rotationAnimation = Tween<double>(begin: 0, end: 1).animate(
    CurvedAnimation(parent: _rotationController, curve: Curves.linear),
  );
  
  // Initialize notifications first, then Firebase
  initializeNotifications().then((_) {
    initializeFirebase();
  });
}
  
  @override
  void dispose() {
    alertCheckTimer?.cancel();
    regularDataTimer?.cancel();
    alertExpiryTimer?.cancel();
    _pulseController.dispose();
    _rotationController.dispose();
    super.dispose();
  }
  
  Future<void> initializeFirebase() async {
    try {
      // Test Firebase connection with a simple request
      String testUrl = "$firebaseHost/.json";
      final response = await http.get(Uri.parse(testUrl)).timeout(Duration(seconds: 10));
      
      if (response.statusCode == 200) {
        setState(() {
          isFirebaseConnected = true;
          hasInitialized = true;
          connectionStatus = "Connected - Monitoring";
        });
        
        // Start monitoring only after successful Firebase connection
        startMonitoring();
        print("✅ Firebase initialized successfully");
      } else {
        throw Exception("Firebase returned status: ${response.statusCode}");
      }
    } catch (e) {
      setState(() {
        isFirebaseConnected = false;
        hasInitialized = true;
        connectionStatus = "Connection Failed - Unable to reach Firebase";
      });
      print("❌ Firebase initialization failed: $e");
      
      // Retry connection every 30 seconds
      Timer(Duration(seconds: 30), () {
        if (!isFirebaseConnected) {
          initializeFirebase();
        }
      });
    }
  }
  
  void startMonitoring() {
    if (!isFirebaseConnected) return;
    
    // Check for alerts every 1 second (as requested)
    alertCheckTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (isFirebaseConnected) {
        checkForAlerts();
      }
    });
    
    // Update regular data every 3 seconds
    regularDataTimer = Timer.periodic(Duration(seconds: 3), (timer) {
      if (isFirebaseConnected) {
        fetchRegularData();
      }
    });
    
    // Timer to update alert time remaining every second
    alertExpiryTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      updateAlertTimeRemaining();
    });
    
    // Initial data fetch
    checkForAlerts();
    fetchRegularData();
  }
  
  void updateAlertTimeRemaining() {
    if (isHighTremor && lastHighTremorTime != null) {
      DateTime now = DateTime.now();
      int minutesElapsed = now.difference(lastHighTremorTime!).inMinutes;
      int minutesRemaining = 15 - minutesElapsed;
      
      if (minutesRemaining > 0) {
        int secondsRemaining = 59 - (now.difference(lastHighTremorTime!).inSeconds % 60);
        setState(() {
          alertTimeRemaining = "${minutesRemaining}m ${secondsRemaining}s remaining";
        });
      } else {
        // Alert has expired
        setState(() {
          isHighTremor = false;
          hasNewAlert = false;
          currentAlertKey = "";
          alertTimeRemaining = "";
          connectionStatus = "Connected - No Active Alerts";
        });
        _pulseController.stop();
        print("🕐 Alert expired after 15 minutes - clearing status");
      }
    }
  }
  
  Future<void> checkForAlerts() async {
    if (!isFirebaseConnected) return;
    
    try {
      alertCheckCount++;
      String alertUrl = "$firebaseHost/alerts/$deviceId.json";
      
      final response = await http.get(Uri.parse(alertUrl)).timeout(Duration(seconds: 5));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        
        if (data != null && data is Map && data.isNotEmpty) {
          // Find the most recent alert by timestamp
          String? latestAlertKey;
          int latestTimestamp = 0;
          Map<String, dynamic>? latestAlertData;
          
          data.forEach((key, value) {
            if (value is Map && value['alert_timestamp'] != null) {
              int timestamp = value['alert_timestamp'];
              if (timestamp > latestTimestamp) {
                latestTimestamp = timestamp;
                latestAlertKey = key;
                latestAlertData = Map<String, dynamic>.from(value);
              }
            }
          });
          
          if (latestAlertKey != null && latestAlertData != null) {
            // Convert Unix timestamp to DateTime (your timestamps appear to be in seconds)
            DateTime alertTime = DateTime.fromMillisecondsSinceEpoch(latestTimestamp * 1000);
            DateTime now = DateTime.now();
            
            // Debug print
            print("🔍 Latest alert: $latestAlertKey at $alertTime");
            print("🔍 Time difference: ${now.difference(alertTime).inMinutes} minutes");
            
            // Check if the alert is within the 15-minute window
            bool isWithin15Minutes = now.difference(alertTime).inMinutes < 15;
            
            if (isWithin15Minutes) {
              // Check if this is a newer alert than what we currently have
              bool isNewerAlert = latestTimestamp > currentAlertUnixTime;
              bool isNewAlertKey = currentAlertKey != latestAlertKey;
              
              setState(() {
                // Always update to the latest alert if it's newer or if no current alert
                if (isNewerAlert || !isHighTremor || isNewAlertKey) {
                  isHighTremor = true;
                  currentAlertKey = latestAlertKey!;
                  currentAlertUnixTime = latestTimestamp;
                  lastHighTremorTime = alertTime;
                  alertTimestamp = latestAlertData!['alert_datetime'] ?? alertTime.toString();
                  
                  // Mark as new alert if it's a different key or newer timestamp
                  hasNewAlert = isNewAlertKey || isNewerAlert;
                  
                  // Update alert tremor data from the latest alert
                  _updateAlertTremorData(latestAlertData!);
                  
                  // Store in alert history
                  alertHistory[latestAlertKey!] = {
                    'data': latestAlertData,
                    'timestamp': alertTime,
                    'processed_at': DateTime.now(),
                  };
                  
                  // Update connection status
                  if (hasNewAlert) {
                    connectionStatus = "🚨 NEW TREMOR ALERT DETECTED";
                    _pulseController.repeat(reverse: true);
                    triggerVibration();
                    sendTremorNotification(latestAlertData!);
                    print("🚨 NEW/UPDATED ALERT: $latestAlertKey at $alertTimestamp (timestamp: $latestTimestamp)");
                  } else {
                    connectionStatus = "⚠️ TREMOR ALERT ACTIVE";
                  }
                }
              });
              
              return; // Exit early since we found an active alert
            } else {
              print("🕐 Alert found but outside 15-minute window: ${now.difference(alertTime).inMinutes} minutes old");
            }
          }
        }
        
        // No alerts within 15 minutes found - clear alert status if currently active
        if (isHighTremor) {
          setState(() {
            isHighTremor = false;
            hasNewAlert = false;
            currentAlertKey = "";
            currentAlertUnixTime = 0;
            alertTimeRemaining = "";
            connectionStatus = "Connected - No High Tremor Detected";
          });
          _pulseController.stop();
          print("🕐 No recent alerts found - clearing status");
        } else if (!isHighTremor && connectionStatus != "Connected - No High Tremor Detected") {
          setState(() {
            connectionStatus = "Connected - No High Tremor Detected";
          });
        }
        
      } else {
        print("⚠️ Alert check HTTP error: ${response.statusCode}");
      }
   
      
    } catch (e) {
      print("⚠️ Alert check network error: $e");
      // Don't change connection status on network errors to avoid flickering
    }

  }
  
  Future<void> fetchRegularData() async {
    if (!isFirebaseConnected) return;
    
    try {
      dataUpdateCount++;
      String dataUrl = "$firebaseHost/tremor_data/$deviceId.json";
      
      final response = await http.get(Uri.parse(dataUrl)).timeout(Duration(seconds: 5));
      
      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        
        if (decoded != null && decoded is Map) {
          final Map<String, dynamic> data = Map<String, dynamic>.from(decoded);
          
          setState(() {
            lastDataUpdateTime = DateTime.now();
            
            // Always update regular data regardless of alert status
            _updateRegularTremorData(data);
            
            // Update connection status only if no active alert
            if (!isHighTremor) {
              bool pdDetected = data['pd_detected'] == true;
              if (pdDetected) {
                connectionStatus = "🟡 Connected - Tremor Detected (Normal Level)";
              } else if (connectionStatus == "Connected - Monitoring") {
                connectionStatus = "Connected - No High Tremor Detected";
              }
            }
          });
        } else {
          // No regular data available yet - this is normal
          if (!isHighTremor && connectionStatus == "Connected - Monitoring") {
            setState(() {
              connectionStatus = "Connected - Waiting for data";
            });
          }
        }
      } else {
        print("⚠️ Regular data HTTP error: ${response.statusCode}");
      }
      
    } catch (e) {
      print("⚠️ Regular data network error: $e");
    }
  }
  
  void _updateRegularTremorData(Map<String, dynamic> data) {
    // Update regular tremor analysis data
    regularDominantFrequency = (data['dominant_frequency'] ?? regularDominantFrequency).toDouble();
    regularTremorAmplitude = (data['tremor_amplitude'] ?? regularTremorAmplitude).toDouble();
    regularRhythmicity = (data['rhythmicity'] ?? regularRhythmicity).toDouble();
    regularHarmonicRatio = (data['harmonic_ratio'] ?? regularHarmonicRatio).toDouble();
    
    // Update regular tremor type
    bool newIsRestTremor = data['is_rest_tremor'] ?? false;
    bool newIsPosturalTremor = data['is_postural_tremor'] ?? false;
    
    regularIsRestTremor = newIsRestTremor;
    regularIsPosturalTremor = newIsPosturalTremor;
    
    if (regularIsRestTremor) {
      regularTremorType = "REST";
    } else if (regularIsPosturalTremor) {
      regularTremorType = "POSTURAL";
    } else {
      regularTremorType = "NONE";
    }
    
    regularLastUpdateTime = data['timestamp_readable'] ?? DateTime.now().toString();
    
    print("📊 Updated regular tremor data - Type: $regularTremorType, Freq: ${regularDominantFrequency.toStringAsFixed(1)}Hz, Amplitude: ${regularTremorAmplitude.toStringAsFixed(3)}");
  }
  
  void _updateAlertTremorData(Map<String, dynamic> data) {
    // Update alert tremor analysis data
    alertDominantFrequency = (data['dominant_frequency'] ?? alertDominantFrequency).toDouble();
    alertTremorAmplitude = (data['tremor_amplitude'] ?? alertTremorAmplitude).toDouble();
    alertRhythmicity = (data['rhythmicity'] ?? alertRhythmicity).toDouble();
    alertHarmonicRatio = (data['harmonic_ratio'] ?? alertHarmonicRatio).toDouble();
    
    // Update alert tremor type
    bool newIsRestTremor = data['is_rest_tremor'] ?? false;
    bool newIsPosturalTremor = data['is_postural_tremor'] ?? false;
    
    alertIsRestTremor = newIsRestTremor;
    alertIsPosturalTremor = newIsPosturalTremor;
    
    if (alertIsRestTremor) {
      alertTremorType = "REST";
    } else if (alertIsPosturalTremor) {
      alertTremorType = "POSTURAL";
    } else {
      alertTremorType = "NONE";
    }
    
    print("🚨 Updated alert tremor data - Type: $alertTremorType, Freq: ${alertDominantFrequency.toStringAsFixed(1)}Hz, Amplitude: ${alertTremorAmplitude.toStringAsFixed(3)}");
  }
  
  Color getStatusColor() {
    if (!hasInitialized) return Colors.orange;
    if (!isFirebaseConnected) return Colors.red;
    if (isHighTremor && !hasNewAlert) return Colors.green;
    if (isHighTremor && hasNewAlert) return Colors.red.shade800;
    return Colors.green;
  }
  
  // Helper method to create safe icons with fallback text
  Widget createSafeIcon(IconData iconData, {double size = 24, Color? color, String? fallbackText}) {
    return Icon(
      iconData,
      size: size,
      color: color,
      // Add semantic label for accessibility
      semanticLabel: fallbackText ?? iconData.toString(),
    );
  }
  
  IconData getStatusIcon() {
    if (!hasInitialized) return Icons.hourglass_empty;
    if (!isFirebaseConnected) return Icons.cloud_off;
    if (isHighTremor) return hasNewAlert ? Icons.new_releases : Icons.warning;
    return Icons.check_circle;
  }
  
  String getMainStatusText() {
    if (!hasInitialized) return 'INITIALIZING...';
    if (!isFirebaseConnected) return 'CONNECTION FAILED';
    if (isHighTremor) {
      return hasNewAlert ? 'NEW HIGH TREMOR ALERT!' : 'HIGH TREMOR DETECTED';
    }
    return 'NO HIGH TREMOR DETECTED';
  }
  
  @override
  Widget build(BuildContext context) {
    if (!isFirebaseConnected) {
      _rotationController.repeat();
    } else {
      _rotationController.stop();
    }
    
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Parkinson\'s Tremor Monitor',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        backgroundColor: getStatusColor(),
        elevation: 0,
        centerTitle: true,
        actions: [
          if (isHighTremor && hasNewAlert)
            Container(
              margin: EdgeInsets.only(right: 16),
              child: AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (context, child) {
                  return Transform.scale(
                    scale: _pulseAnimation.value,
                    child: createSafeIcon(
                      Icons.fiber_new,
                      color: Colors.white,
                      size: 28,
                      fallbackText: "NEW",
                    ),
                  );
                },
              ),
            ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              getStatusColor().withOpacity(0.1),
              Colors.grey.shade50,
              Colors.white,
            ],
            stops: [0.0, 0.3, 1.0],
          ),
        ),
        child: RefreshIndicator(
          onRefresh: () async {
            if (isFirebaseConnected) {
              await Future.wait([
                checkForAlerts(),
                fetchRegularData(),
              ]);
            } else {
              await initializeFirebase();
            }
          },
          child: SingleChildScrollView(
            physics: AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.all(16.0),
            child: Column(
              children: [
                // Main Status Card with enhanced alert indication
                _buildMainStatusCard(),
                
                SizedBox(height: 20),
                
                // High Tremor Alert Details Card - Only shown when there's an active alert
                if (isHighTremor)
                  _buildAlertDetailsCard(),
                
                if (isHighTremor)
                  SizedBox(height: 20),
                
                // Regular Tremor Details Card - Always shown when connected
                if (isFirebaseConnected)
                  _buildRegularTremorDetailsCard(),
                
                SizedBox(height: 20),
                
                // System Status Card
                _buildSystemStatusCard(),
                
                SizedBox(height: 20),
                
                // Enhanced action buttons
                _buildActionButtons(),
              ],
            ),
          ),
        ),
      ),
    );
  }
  
  Widget _buildMainStatusCard() {
    return AnimatedContainer(
      duration: Duration(milliseconds: 500),
      child: Card(
        elevation: isHighTremor && hasNewAlert ? 16 : 12,
        shadowColor: isHighTremor && hasNewAlert ? Colors.red.withOpacity(0.5) : Colors.black26,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.all(32.0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: !isFirebaseConnected 
                  ? [Colors.red.shade50, Colors.red.shade100]
                  : (isHighTremor && hasNewAlert)
                      ? [Colors.red.shade50, Colors.red.shade100, Colors.red.shade50]
                      : [Colors.green.shade50, Colors.green.shade100, Colors.green.shade50],
            ),
            border: isHighTremor && hasNewAlert
                ? Border.all(color: Colors.red.shade800, width: 3)
                : null,
            boxShadow: isHighTremor && hasNewAlert ? [
              BoxShadow(
                color: Colors.red.withOpacity(0.3),
                blurRadius: 15,
                spreadRadius: 2,
              )
            ] : null,
          ),
          child: Column(
            children: [
              // Status Icon with animation
              AnimatedBuilder(
                animation: !isFirebaseConnected ? _rotationAnimation : _pulseAnimation,
                builder: (context, child) {
                  if (!isFirebaseConnected) {
                    return Transform.rotate(
                      angle: _rotationAnimation.value * 2 * 3.14159,
                      child: createSafeIcon(
                        getStatusIcon(),
                        size: 80,
                        color: getStatusColor(),
                        fallbackText: "Loading",
                      ),
                    );
                  } else if (isHighTremor && hasNewAlert) {
                    return Transform.scale(
                      scale: _pulseAnimation.value,
                      child: createSafeIcon(
                        getStatusIcon(),
                        size: 80,
                        color: getStatusColor(),
                        fallbackText: "Alert",
                      ),
                    );
                  } else {
                    return createSafeIcon(
                      getStatusIcon(),
                      size: 80,
                      color: getStatusColor(),
                      fallbackText: "Status",
                    );
                  }
                },
              ),
              SizedBox(height: 20),
              
              // Main Status Text
              AnimatedDefaultTextStyle(
                duration: Duration(milliseconds: 300),
                style: TextStyle(
                  fontSize: isHighTremor && hasNewAlert ? 28 : 26,
                  fontWeight: FontWeight.bold,
                  color: getStatusColor(),
                ),
                child: Text(
                  getMainStatusText(),
                  textAlign: TextAlign.center,
                ),
              ),
              
              SizedBox(height: 12),
              
              // Connection Status
              Text(
                connectionStatus,
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey.shade700,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              
              // Alert Information
              if (isHighTremor && alertTimestamp.isNotEmpty) ...[
                SizedBox(height: 20),
                Container(
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: hasNewAlert 
                          ? [Colors.red.shade200, Colors.red.shade300]
                          : [Colors.orange.shade100, Colors.orange.shade200],
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: hasNewAlert ? Colors.red.shade800 : Colors.orange.shade400,
                      width: hasNewAlert ? 2 : 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (hasNewAlert ? Colors.red : Colors.orange).withOpacity(0.2),
                        blurRadius: 8,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      if (hasNewAlert)
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.red.shade800,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '🆕 NEW ALERT',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      SizedBox(height: hasNewAlert ? 12 : 0),
                      
                      Row(
                        children: [
                          createSafeIcon(
                            Icons.access_time, 
                            color: hasNewAlert ? Colors.red.shade700 : Colors.orange.shade700, 
                            size: 18,
                            fallbackText: "Time"
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Alert Time: $alertTimestamp',
                              style: TextStyle(
                                fontSize: 14,
                                color: hasNewAlert ? Colors.red.shade800 : Colors.orange.shade800,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      
                      if (alertTimeRemaining.isNotEmpty) ...[
                        SizedBox(height: 8),
                        Row(
                          children: [
                            createSafeIcon(
                              Icons.timer, 
                              color: hasNewAlert ? Colors.red.shade700 : Colors.orange.shade700, 
                              size: 18,
                              fallbackText: "Timer"
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Display Time: $alertTimeRemaining',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: hasNewAlert ? Colors.red.shade700 : Colors.orange.shade700,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      
                      if (currentAlertKey.isNotEmpty) ...[
                        SizedBox(height: 8),
                        Row(
                          children: [
                            createSafeIcon(
                              Icons.fingerprint, 
                              color: hasNewAlert ? Colors.red.shade600 : Colors.orange.shade600, 
                              size: 16,
                              fallbackText: "ID"
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Alert ID: ${currentAlertKey.length > 20 ? currentAlertKey.substring(currentAlertKey.length - 20) : currentAlertKey}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: hasNewAlert ? Colors.red.shade600 : Colors.orange.shade600,
                                  fontStyle: FontStyle.italic,
                      ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
  Widget _buildAlertDetailsCard() {
    return Card(
      elevation: 12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: hasNewAlert 
                ? [Colors.red.shade50, Colors.red.shade100]
                : [Colors.orange.shade50, Colors.orange.shade100],
          ),
        ),
        child: Padding(
          padding: EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header with alert indicator
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: hasNewAlert ? Colors.red.shade100 : Colors.orange.shade100,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: createSafeIcon(
                          Icons.warning,
                          color: hasNewAlert ? Colors.red.shade700 : Colors.orange.shade700,
                          size: 24,
                          fallbackText: "Warning",
                        ),
                      ),
                      SizedBox(width: 12),
                      Text(
                        'High Tremor Data',
                        style: TextStyle(
                         fontSize: 22,
                        fontWeight: FontWeight.bold,
                          color: hasNewAlert ? Colors.red.shade800 : Colors.orange.shade800,
                        ),
                      ),
                    ],
                  ),
                  if (hasNewAlert)
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.red.shade800,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'NEW',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
              
              SizedBox(height: 20),
              
              // Alert Tremor Analysis Data
              _buildTremorDataSection(
                title: "Alert Tremor Analysis",
                dominantFreq: alertDominantFrequency,
                amplitude: alertTremorAmplitude,
                rhythmicity: alertRhythmicity,
                harmonicRatio: alertHarmonicRatio,
                tremorType: alertTremorType,
                isRestTremor: alertIsRestTremor,
                isPosturalTremor: alertIsPosturalTremor,
                isAlert: true,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRegularTremorDetailsCard() {
    return Card(
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.blue.shade50, Colors.blue.shade100],
          ),
        ),
        child: Padding(
          padding: EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: createSafeIcon(
                      Icons.analytics,
                      color: Colors.blue.shade700,
                      size: 24,
                      fallbackText: "Analytics",
                    ),
                  ),
                  SizedBox(width: 12),
                  Text(
                    'Tremor Analysis',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue.shade800,
                    ),
                  ),
                ],
              ),
              
              SizedBox(height: 20),
              
              // Regular Tremor Analysis Data
              _buildTremorDataSection(
                title: "Live Monitoring Data",
                dominantFreq: regularDominantFrequency,
                amplitude: regularTremorAmplitude,
                rhythmicity: regularRhythmicity,
                harmonicRatio: regularHarmonicRatio,
                tremorType: regularTremorType,
                isRestTremor: regularIsRestTremor,
                isPosturalTremor: regularIsPosturalTremor,
                isAlert: false,
              ),
              
              if (regularLastUpdateTime.isNotEmpty) ...[
                SizedBox(height: 16),
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Row(
                    children: [
                      createSafeIcon(
                        Icons.schedule,
                        color: Colors.blue.shade600,
                        size: 16,
                        fallbackText: "Last Update",
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Last Update: $regularLastUpdateTime',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.blue.shade700,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTremorDataSection({
    required String title,
    required double dominantFreq,
    required double amplitude,
    required double rhythmicity,
    required double harmonicRatio,
    required String tremorType,
    required bool isRestTremor,
    required bool isPosturalTremor,
    required bool isAlert,
  }) {
    Color primaryColor = isAlert 
        ? (hasNewAlert ? Colors.red.shade700 : Colors.orange.shade700)
        : Colors.blue.shade700;
    Color backgroundColor = isAlert 
        ? (hasNewAlert ? Colors.red.shade50 : Colors.orange.shade50)
        : Colors.blue.shade50;
    
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: primaryColor.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: primaryColor,
            ),
          ),
          SizedBox(height: 16),
          
          // Tremor Type
          _buildDataRow(
            'Tremor Type',
            tremorType,
            createSafeIcon(Icons.category, color: primaryColor, size: 20, fallbackText: "Type"),
            primaryColor,
          ),
          
          // Dominant Frequency
          _buildDataRow(
            'Dominant Frequency',
            '${dominantFreq.toStringAsFixed(1)} Hz',
            createSafeIcon(Icons.graphic_eq, color: primaryColor, size: 20, fallbackText: "Frequency"),
            primaryColor,
          ),
          
          // Tremor Amplitude
          _buildDataRow(
            'Tremor Amplitude',
            amplitude.toStringAsFixed(3),
            createSafeIcon(Icons.show_chart, color: primaryColor, size: 20, fallbackText: "Amplitude"),
            primaryColor,
          ),
          
          // Rhythmicity
          _buildDataRow(
            'Rhythmicity',
            '${(rhythmicity * 100).toStringAsFixed(1)}%',
            createSafeIcon(Icons.music_note, color: primaryColor, size: 20, fallbackText: "Rhythm"),
            primaryColor,
          ),
          
          // Harmonic Ratio
          _buildDataRow(
            'Harmonic Ratio',
            harmonicRatio.toStringAsFixed(2),
            createSafeIcon(Icons.equalizer, color: primaryColor, size: 20, fallbackText: "Harmonic"),
            primaryColor,
          ),
          
          SizedBox(height: 12),
          
          // Tremor Classification
          Row(
            children: [
              createSafeIcon(Icons.info_outline, color: primaryColor, size: 20, fallbackText: "Info"),
              SizedBox(width: 8),
              Text(
                'Classification:',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: primaryColor,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              _buildClassificationChip('Rest Tremor', isRestTremor, primaryColor),
              _buildClassificationChip('Postural Tremor', isPosturalTremor, primaryColor),
            ],
          ),
        ],
      ),
    );
  }
Widget _buildDataRow(String label, String value, Widget icon, Color color) {
  return Padding(
    padding: EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        icon,
        SizedBox(width: 8), // Reduced spacing
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  color: color,
                  fontSize: 13, // Slightly smaller font
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
              SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: color.withOpacity(0.8),
                  fontSize: 14,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
  Widget _buildClassificationChip(String label, bool isActive, Color primaryColor) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isActive ? primaryColor : Colors.grey.shade200,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isActive ? primaryColor : Colors.grey.shade400,
          width: 1,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: isActive ? Colors.white : Colors.grey.shade600,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildSystemStatusCard() {
    return Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                createSafeIcon(
                  Icons.settings,
                  color: Colors.grey.shade700,
                  size: 20,
                  fallbackText: "Settings",
                ),
                SizedBox(width: 8),
                Text(
                  'System Status',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade800,
                  ),
                ),
              ],
            ),
            SizedBox(height: 16),
            
            _buildStatusRow('Firebase Connection', isFirebaseConnected ? 'Connected' : 'Disconnected', isFirebaseConnected),
            _buildStatusRow('Device ID', deviceId, true),
            _buildStatusRow('Alert Checks', '$alertCheckCount', true),
            _buildStatusRow('Data Updates', '$dataUpdateCount', true),
            
            if (lastDataUpdateTime != null) ...[
              SizedBox(height: 8),
              Text(
                'Last Data Update: ${lastDataUpdateTime!.toLocal().toString().substring(0, 19)}',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusRow(String label, String value, bool isGood) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade700,
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isGood ? Colors.green.shade700 : Colors.red.shade700,
                ),
              ),
              SizedBox(width: 4),
              createSafeIcon(
                isGood ? Icons.check_circle : Icons.error,
                color: isGood ? Colors.green.shade700 : Colors.red.shade700,
                size: 16,
                fallbackText: isGood ? "Good" : "Error",
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Column(
      children: [
        // Refresh Button
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton.icon(
            onPressed: () async {
              if (isFirebaseConnected) {
                await Future.wait([
                  checkForAlerts(),
                  fetchRegularData(),
                ]);
              } else {
                await initializeFirebase();
              }
            },
            icon: createSafeIcon(
              Icons.refresh,
              color: Colors.white,
              size: 20,
              fallbackText: "Refresh",
            ),
            label: Text(
              isFirebaseConnected ? 'Refresh Data' : 'Retry Connection',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: getStatusColor(),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              elevation: 4,
            ),
          ),
        ),
        
        SizedBox(height: 12),
        
        // Acknowledge Alert Button (only shown for new alerts)
        if (isHighTremor && hasNewAlert)
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              onPressed: () {
                setState(() {
                  hasNewAlert = false;
                  connectionStatus = "⚠️ TREMOR ALERT ACTIVE (Acknowledged)";
                });
                _pulseController.stop();
              },
              icon: createSafeIcon(
                Icons.check,
                color: Colors.white,
                size: 20,
                fallbackText: "Acknowledge",
              ),
              label: Text(
                'Acknowledge Alert',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange.shade600,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 4,
              ),
            ),
          ),
      ],
    );
  }

  // Initialize notifications and background service
Future<void> initializeNotifications() async {
  // Request permissions
  await Permission.notification.request();
  
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  
  const InitializationSettings initializationSettings =
      InitializationSettings(android: initializationSettingsAndroid);
  
  await flutterLocalNotificationsPlugin.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: (NotificationResponse response) {
      // Handle notification tap
    },
  );
  
  notificationsInitialized = true;
  
  // Initialize background service
  await initializeBackgroundService();
}

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();
  
  await service.configure(
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'tremor_monitoring',
      initialNotificationTitle: 'Tremor Monitor',
      initialNotificationContent: 'Monitoring for tremor alerts...',
      foregroundServiceNotificationId: 888,
    ),
  );
  
  backgroundServiceRunning = true;
}

// Background service callback
@pragma('vm:entry-point')
 Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

@pragma('vm:entry-point')
 void onStart(ServiceInstance service) async {
  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });
    
    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }
  
  // Background monitoring logic
  Timer.periodic(Duration(seconds: 5), (timer) async {
    await checkForAlertsBackground();
  });
}

// Background alert checking
Future<void> checkForAlertsBackground() async {
  try {
    final String firebaseHost = "";
    final String deviceId = "";
    String alertUrl = "$firebaseHost/alerts/$deviceId.json";
    
    final response = await http.get(Uri.parse(alertUrl)).timeout(Duration(seconds: 5));
    
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      
      if (data != null && data is Map && data.isNotEmpty) {
        // Find the most recent alert
        String? latestAlertKey;
        int latestTimestamp = 0;
        
        data.forEach((key, value) {
          if (value is Map && value['alert_timestamp'] != null) {
            int timestamp = value['alert_timestamp'];
            if (timestamp > latestTimestamp) {
              latestTimestamp = timestamp;
              latestAlertKey = key;
            }
          }
        });
        
        if (latestAlertKey != null) {
          DateTime alertTime = DateTime.fromMillisecondsSinceEpoch(latestTimestamp * 1000);
          DateTime now = DateTime.now();
          
          if (now.difference(alertTime).inMinutes < 15) {
            // Send notification and vibrate
            await sendTremorNotification(data[latestAlertKey]);
            await triggerVibration();
          }
        }
      }
    }
  } catch (e) {
    print("Background alert check failed: $e");
  }
}

// Send notification
Future<void> sendTremorNotification(Map<String, dynamic> alertData) async {
  if (!notificationsInitialized) return;
  
  const AndroidNotificationDetails androidPlatformChannelSpecifics =
      AndroidNotificationDetails(
    'tremor_alerts',
    'Tremor Alerts',
    channelDescription: 'High tremor alert notifications',
    importance: Importance.max,
    priority: Priority.high,
    showWhen: true,
    enableVibration: true,
    playSound: true,
  );
  
  const NotificationDetails platformChannelSpecifics =
      NotificationDetails(android: androidPlatformChannelSpecifics);
  
  String alertTime = alertData['alert_datetime'] ?? DateTime.now().toString();
  double frequency = (alertData['dominant_frequency'] ?? 0.0).toDouble();
  
  await flutterLocalNotificationsPlugin.show(
    DateTime.now().millisecondsSinceEpoch.remainder(100000),
    '🚨 HIGH TREMOR ALERT',
    'Tremor detected at $alertTime\nFrequency: ${frequency.toStringAsFixed(1)} Hz',
    platformChannelSpecifics,
  );
}

// Trigger vibration
Future<void> triggerVibration() async {
  if (await Vibration.hasVibrator() ?? false) {
    // Strong vibration pattern for alerts
    await Vibration.vibrate(
      pattern: [0, 500, 300, 500, 300, 500], // Vibrate, pause, vibrate pattern
      intensities: [0, 255, 0, 255, 0, 255], // Max intensity
    );
  }
}
}