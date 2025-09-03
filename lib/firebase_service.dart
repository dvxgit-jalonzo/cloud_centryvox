import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import 'api_controller.dart';
import 'janus_service.dart';
import 'storage_controller.dart';

class FirebaseService {
  static final FirebaseService _instance = FirebaseService._internal();
  factory FirebaseService() => _instance;
  FirebaseService._internal();

  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;
  final StorageController storage = StorageController();
  final ApiController apiController = ApiController();

  Future<void> initialize() async {
    // Request permission for notifications
    NotificationSettings settings = await _firebaseMessaging.requestPermission(
      alert: true,
      announcement: false,
      badge: true,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      if (kDebugMode) print('✅ FCM: User granted permission');
    } else if (settings.authorizationStatus ==
        AuthorizationStatus.provisional) {
      if (kDebugMode) print('⚠️ FCM: User granted provisional permission');
    } else {
      if (kDebugMode)
        print('❌ FCM: User declined or has not accepted permission');
    }

    // Get FCM token
    String? token = await _firebaseMessaging.getToken();
    if (token != null) {
      if (kDebugMode) print('📱 FCM Token: $token');
      await storage.storeData('fcm_token', token);

      // Store token generation timestamp to detect reboot scenarios
      await storage.storeData(
        'fcm_token_timestamp',
        DateTime.now().millisecondsSinceEpoch,
      );

      // Register token with server using your existing method
      try {
        await apiController.populateExtensionToken();
        if (kDebugMode)
          print('✅ FCM token registered via populateExtensionToken');
      } catch (e) {
        if (kDebugMode) print('❌ Failed to register FCM token: $e');
      }
    }

    // Listen for token refresh
    _firebaseMessaging.onTokenRefresh.listen((newToken) async {
      if (kDebugMode) print('📱 FCM Token refreshed: $newToken');
      await storage.storeData('fcm_token', newToken);
      await storage.storeData(
        'fcm_token_timestamp',
        DateTime.now().millisecondsSinceEpoch,
      );

      // Update token on server using your existing method
      try {
        await apiController.populateExtensionToken();
        if (kDebugMode) print('✅ FCM token updated via populateExtensionToken');
      } catch (e) {
        if (kDebugMode) print('❌ Failed to update FCM token: $e');
        // Retry after a delay
        await Future.delayed(const Duration(seconds: 5));
        try {
          await apiController.populateExtensionToken();
          if (kDebugMode)
            print('✅ FCM token updated via populateExtensionToken (retry)');
        } catch (retryError) {
          if (kDebugMode)
            print('❌ Failed to update FCM token on retry: $retryError');
        }
      }
    });

    // Handle foreground messages
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    // Handle background messages when app is in background but not terminated
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpenedApp);
  }

  void _handleForegroundMessage(RemoteMessage message) {
    if (kDebugMode)
      print('📱 FCM: Foreground message received: ${message.data}');

    if (message.data['type'] == 'incoming_call') {
      _handleIncomingCall(message.data);
    }
  }

  void _handleMessageOpenedApp(RemoteMessage message) {
    if (kDebugMode) print('📱 FCM: Message opened app: ${message.data}');

    if (message.data['type'] == 'incoming_call') {
      _handleIncomingCall(message.data);
    }
  }

  void _handleIncomingCall(Map<String, dynamic> data) async {
    if (kDebugMode) {
      print('🔥 FIREBASE PUSH RECEIVED - DATA: $data');
      print('📱 Initializing Janus for incoming call...');
    }

    try {
      // Store push notification data FIRST
      await storage.storeData('push_notification_data', {
        'server_call_id': data['server_call_id'],
        'caller_name': data['caller_name'],
        'caller_number': data['caller_number'],
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      
      if (kDebugMode) print('📦 Push notification data stored');

      // Initialize and register Janus
      final janusService = JanusService();
      
      if (kDebugMode) print('🔧 Calling janusService.initialize()...');
      await janusService.initialize();
      
      if (kDebugMode) print('📞 Calling janusService.register()...');
      await janusService.register();

      // Wait for SIP registration to complete
      if (kDebugMode) print('⏳ Waiting 3 seconds for SIP registration...');
      await Future.delayed(const Duration(seconds: 3));

      if (kDebugMode) print('✅ Janus should now be ready - listening for SIP events');

      // Store that initialization is complete
      await storage.storeData('janus_pre_initialized', {
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'server_call_id': data['server_call_id'],
      });

    } catch (e, stackTrace) {
      if (kDebugMode) {
        print('❌ CRITICAL: Janus initialization failed: $e');
        print('📍 Stack trace: $stackTrace');
      }
    }

    if (kDebugMode) print('⏳ Push notification handled - waiting for SIP events from Janus...');
  }

  Future<String?> getToken() async {
    return await _firebaseMessaging.getToken();
  }
}

// Background message handler - must be top-level function
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (kDebugMode) print('📱 FCM: Background message received (app terminated): ${message.data}');

  if (message.data['type'] == 'incoming_call') {
    await _handleBackgroundIncomingCall(message.data);
  }
}

Future<void> _handleBackgroundIncomingCall(Map<String, dynamic> data) async {
  final storage = StorageController();

  if (kDebugMode) {
    print('🔥 FIREBASE PUSH RECEIVED (BACKGROUND/TERMINATED) - DATA: $data');
    print('📱 Initializing Janus for incoming call...');
  }

  try {
    // Store push notification data FIRST
    await storage.storeData('push_notification_data', {
      'server_call_id': data['server_call_id'],
      'caller_name': data['caller_name'],
      'caller_number': data['caller_number'],
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    
    if (kDebugMode) print('📦 Push notification data stored (background)');

    // Initialize and register Janus
    final janusService = JanusService();
    
    if (kDebugMode) print('🔧 Calling janusService.initialize() (background)...');
    await janusService.initialize();
    
    if (kDebugMode) print('📞 Calling janusService.register() (background)...');
    await janusService.register();

    // Wait for SIP registration to complete
    if (kDebugMode) print('⏳ Waiting 3 seconds for SIP registration (background)...');
    await Future.delayed(const Duration(seconds: 3));

    if (kDebugMode) print('✅ Background Janus should now be ready - listening for SIP events');

    // Store that initialization is complete
    await storage.storeData('janus_pre_initialized', {
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'server_call_id': data['server_call_id'],
    });

  } catch (e, stackTrace) {
    if (kDebugMode) {
      print('❌ CRITICAL: Background Janus initialization failed: $e');
      print('📍 Stack trace: $stackTrace');
    }
  }

  if (kDebugMode) print('⏳ Background push handled - waiting for SIP events from Janus...');
}
