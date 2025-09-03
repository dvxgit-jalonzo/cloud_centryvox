import 'dart:convert';
import 'dart:io';

import 'package:cloud_centryvox/api_controller.dart';
import 'package:cloud_centryvox/call_handler_service.dart';
import 'package:cloud_centryvox/firebase_service.dart';
import 'package:cloud_centryvox/my_http_overrides.dart';
import 'package:cloud_centryvox/navigation_service.dart';
import 'package:cloud_centryvox/scan_qrcode_page.dart';
import 'package:cloud_centryvox/storage_controller.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  await Firebase.initializeApp();

  // Set background message handler
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  final storage = StorageController();
  final isQrScanned = await storage.getData('is_qr_scanned') ?? false;

  // Request basic permissions
  if (kDebugMode) print('📱 Requesting permissions...');
  await [
    Permission.microphone,
    Permission.camera,
    Permission.systemAlertWindow,
    Permission.ignoreBatteryOptimizations,
    Permission.phone,
  ].request();

  // Request CallKit notification permissions
  try {
    await FlutterCallkitIncoming.requestNotificationPermission({
      "rationaleMessagePermission":
          "Notification permission is required to show incoming calls.",
      "postNotificationMessageRequired":
          "Please allow notification permission from settings.",
    });
    if (kDebugMode) print('✅ CallKit notification permission requested');
  } catch (e) {
    if (kDebugMode)
      print('❌ Failed to request CallKit notification permission: $e');
  }

  HttpOverrides.global = MyHttpOverrides();

  // Initialize Firebase Service
  await FirebaseService().initialize();

  // Re-register FCM token with backend after reboot/force stop
  await _ensureFCMTokenRegistered();

  // Initialize Call Handler Service
  CallHandlerService().initialize();

  // Handle any CallKit events that occurred while app was terminated
  await _handleTerminatedCallKitEvents();

  if (!isQrScanned) {
    runApp(ScanQrCodePage());
  } else {
    runApp(const Main());
  }
}

/// Ensure FCM token is properly registered with backend after reboot
Future<void> _ensureFCMTokenRegistered() async {
  try {
    if (kDebugMode)
      print('🔄 Ensuring FCM token is registered with backend...');

    final storage = StorageController();

    // Get current FCM token
    final currentToken = await FirebaseMessaging.instance.getToken();
    if (currentToken == null) {
      if (kDebugMode) print('❌ No FCM token available');
      return;
    }

    // Get stored token
    final storedToken = await storage.getData('fcm_token');

    // Check if we need to re-register (token changed or first time)
    if (storedToken != currentToken) {
      if (kDebugMode) print('🔄 FCM token changed, re-registering...');
      await storage.storeData('fcm_token', currentToken);
    } else {
      if (kDebugMode)
        print('📱 FCM token unchanged, but re-registering after reboot...');
    }

    // Always re-register token with backend after app start
    // (in case server lost the token or it became invalid)
    if (kDebugMode) print('🚀 Calling populateExtensionToken...');

    final apiController = ApiController();
    await apiController.populateExtensionToken();

    if (kDebugMode) print('✅ FCM token re-registered successfully');
  } catch (e) {
    if (kDebugMode) print('❌ Failed to ensure FCM token registration: $e');
    // Don't throw - app should continue to work even if token registration fails
  }
}

/// Handle CallKit events that occurred while app was terminated
Future<void> _handleTerminatedCallKitEvents() async {
  try {
    if (kDebugMode) print('🔍 Checking for terminated CallKit events...');

    // Check for any active calls that might have been interacted with
    final activeCalls = await FlutterCallkitIncoming.activeCalls();

    for (var call in activeCalls) {
      if (kDebugMode) print('📞 Found active call on startup: $call');

      // You can add additional logic here to handle specific call states
      // The CallHandlerService.checkPendingCalls() will also handle these
    }

    // Listen for the first event after app launch to catch missed events
    FlutterCallkitIncoming.onEvent.take(1).listen((event) async {
      if (event?.event == Event.actionCallAccept ||
          event?.event == Event.actionCallStart) {
        if (kDebugMode) print('📞 Caught missed accept event on app launch');
        // This will be handled by the regular CallHandlerService listener
      }
    });
  } catch (e) {
    if (kDebugMode) print('❌ Error handling terminated CallKit events: $e');
  }
}

class Main extends StatefulWidget {
  const Main({super.key});

  @override
  State<Main> createState() => _MainState();
}

class _MainState extends State<Main> {
  @override
  void initState() {
    super.initState();
    // Check for pending calls when app starts
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      CallHandlerService().checkPendingCalls();

      // Check if app was opened due to CallKit action
      await _checkCallKitLaunch();
    });
  }

  /// Check if app was launched due to CallKit interaction
  Future<void> _checkCallKitLaunch() async {
    try {
      final storage = StorageController();

      // Check if we have pending call data (means FCM call was received)
      final pendingCallData = await storage.getData('pending_call_data');
      if (pendingCallData != null) {
        if (kDebugMode) {
          print(
            '🚀 App launched with pending call data - likely from CallKit Accept',
          );
        }

        // If app launched and we have pending call data, assume user accepted
        // (pressing decline usually doesn't launch the app)
        final timestamp = pendingCallData['timestamp'] ?? 0;
        final now = DateTime.now().millisecondsSinceEpoch;

        // If call data is recent (within 2 minutes), assume accepted
        if (now - timestamp < 120000) {
          if (kDebugMode)
            print('✅ Recent pending call + app launch = ACCEPTED');

          // Trigger the call handler to process acceptance
          CallHandlerService().handleCallAccept({
            'id': pendingCallData['call_id'],
            'call_id': pendingCallData['call_id'],
          });
        }
      }

      // Also check active calls
      final activeCalls = await FlutterCallkitIncoming.activeCalls();
      if (activeCalls.isNotEmpty) {
        if (kDebugMode) {
          print(
            '📞 App launched with ${activeCalls.length} active CallKit calls',
          );
        }
      }
    } catch (e) {
      if (kDebugMode) print('❌ Error checking CallKit launch: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'CentVox',
      navigatorKey: NavigationService.navigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'CentVox'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: () async {
                final StorageController storage = StorageController();
                final base = await storage.getData("base");
                final accessToken = await storage.getData("accessToken");
                final headers = {
                  'Authorization': 'Bearer $accessToken',
                  'Accept': 'application/json',
                  'Content-Type': 'application/json',
                };
                final route = "$base/api/mobile-call-session/1756278668.365";
                final extensionNumber = await storage.getData(
                  "extensionNumber",
                );
                final response = await http.put(
                  Uri.parse(route),
                  headers: headers,
                  body: jsonEncode({
                    'status': "ready",
                    'extension': extensionNumber,
                    'action':
                        "ready", // 'accept', 'decline', 'hangup', or 'accept_ready'
                    'timestamp': DateTime.now().millisecondsSinceEpoch,
                  }),
                );
                if (response.statusCode == 200) {
                  if (kDebugMode)
                    print('✅ Call response (ready) sent successfully');
                } else {
                  if (kDebugMode) {
                    print(
                      '❌ Failed to send call response: ${response.statusCode}',
                    );
                  }
                }
              },
              child: Text("test"),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: () async {
                // Test CallKit directly
                if (kDebugMode) print('🧪 Testing CallKit directly...');
                try {
                  await FlutterCallkitIncoming.showCallkitIncoming(
                    CallKitParams(
                      id: "test-call-123",
                      nameCaller: "Test Caller",
                      appName: 'CentVox',
                      handle: "+1234567890",
                      type: 0,
                      textAccept: 'Accept',
                      textDecline: 'Decline',
                      duration: 30000,
                      android: const AndroidParams(
                        isCustomNotification: false,
                        isShowFullLockedScreen: true,
                        backgroundColor: '#075E54',
                        actionColor: '#4CAF50',
                        isShowCallID: false,
                      ),
                      ios: IOSParams(iconName: 'CallKitLogo', ringtonePath: ''),
                    ),
                  );
                  if (kDebugMode) {
                    print('✅ Test CallKit triggered successfully!');
                  }
                } catch (e) {
                  if (kDebugMode) print('❌ Test CallKit failed: $e');
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: Text("Test CallKit"),
            ),
          ],
        ),
      ),
    );
  }
}
