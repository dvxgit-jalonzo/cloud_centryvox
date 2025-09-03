import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'api_controller.dart';
import 'janus_service.dart';
import 'navigation_service.dart';
import 'ongoing_call.dart';
import 'storage_controller.dart';
import 'call_response_service.dart';
import 'api_service.dart';

class CallHandlerService {
  static final CallHandlerService _instance = CallHandlerService._internal();
  factory CallHandlerService() => _instance;
  CallHandlerService._internal();

  final StorageController storage = StorageController();
  final JanusService janusService = JanusService();
  final CallResponseService callResponseService = CallResponseService();
  final ApiService apiService = ApiService();
  StreamSubscription<CallEvent?>? _callEventSubscription;
  
  bool _isAppFromBackground = false;
  bool _isInitializing = false;

  void initialize() {
    _callEventSubscription = FlutterCallkitIncoming.onEvent.listen(_handleCallEvent);
    // Track app activity for background detection
    _trackAppActivity();
  }

  /// Track app activity timestamp for background launch detection
  void _trackAppActivity() {
    // Update timestamp every 5 seconds while app is active
    Timer.periodic(const Duration(seconds: 5), (timer) async {
      try {
        await storage.storeData('last_active_time', DateTime.now().millisecondsSinceEpoch);
        
        // Also verify FCM token is still valid periodically (every 30 seconds)
        final now = DateTime.now().millisecondsSinceEpoch;
        final lastTokenCheck = await storage.getData('last_token_check') ?? 0;
        
        if (now - lastTokenCheck > 30000) { // 30 seconds
          await storage.storeData('last_token_check', now);
          await _verifyFCMTokenHealth();
        }
      } catch (e) {
        if (kDebugMode) print('❌ Error tracking app activity: $e');
      }
    });
  }

  /// Verify FCM token health and re-register if needed
  Future<void> _verifyFCMTokenHealth() async {
    try {
      final currentToken = await FirebaseMessaging.instance.getToken();
      final storedToken = await storage.getData('fcm_token');
      
      if (currentToken != null && currentToken != storedToken) {
        if (kDebugMode) print('🔄 FCM token changed, re-registering...');
        await storage.storeData('fcm_token', currentToken);
        
        final apiController = ApiController();
        await apiController.populateExtensionToken();
        
        if (kDebugMode) print('✅ FCM token health check - re-registered');
      }
    } catch (e) {
      if (kDebugMode) print('⚠️ FCM token health check failed: $e');
    }
  }

  void dispose() {
    _callEventSubscription?.cancel();
  }

  void _handleCallEvent(CallEvent? event) async {
    if (event == null) return;
    if (kDebugMode) print('📞 CallKit Event: ${event.event} - ${event.body}');

    switch (event.event) {
      case Event.actionCallIncoming:
        // Call is ringing
        break;

      case Event.actionCallStart:
        // User pressed answer button
        await handleCallAccept(event.body);
        break;

      case Event.actionCallAccept:
        // Call was accepted
        await handleCallAccept(event.body);
        break;

      case Event.actionCallDecline:
        // User declined call
        await _handleCallDecline(event.body);
        break;

      case Event.actionCallEnded:
        // Call ended
        await _handleCallEnd(event.body);
        break;

      case Event.actionCallTimeout:
        // Call timed out
        await _handleCallTimeout(event.body);
        break;

      case Event.actionDidUpdateDevicePushTokenVoip:
        // VoIP token updated
        if (kDebugMode) print('📱 VoIP Token updated: ${event.body['deviceTokenVoIP']}');
        break;

      default:
        if (kDebugMode) print('🤔 Unhandled CallKit event: ${event.event}');
    }
  }

  Future<void> handleCallAccept(Map<String, dynamic> callData) async {
    try {
      if (kDebugMode) print('✅ Call accepted: $callData');

      final callId = callData['id'] ?? callData['call_id'];
      if (callId == null) {
        if (kDebugMode) print('❌ No call ID found in call data');
        return;
      }

      // Detect if app was launched from background/terminated state
      _isAppFromBackground = await _detectBackgroundLaunch();
      if (kDebugMode) print('🔍 Background detection result: $_isAppFromBackground');
      
      if (_isAppFromBackground && !_isInitializing) {
        _isInitializing = true;
        if (kDebugMode) print('📱 App launched from background - initializing for call...');
        await _initializeForIncomingCall(callId);
        _isInitializing = false;
      } else {
        // App was already running - proceed with normal flow
        if (kDebugMode) print('📱 App was already running - normal accept flow');
        await _acceptCallNormal(callId);
      }
      
    } catch (e) {
      if (kDebugMode) print('❌ Error accepting call: $e');
      _isInitializing = false;
      await FlutterCallkitIncoming.endAllCalls();
      
      // Try to notify server that call failed
      final callId = callData['id'] ?? callData['call_id'];
      if (callId != null) {
        await callResponseService.endCall(callId);
      }
    }
  }

  /// Initialize app for incoming call from background/terminated state
  Future<void> _initializeForIncomingCall(String callId) async {
    try {
      // Check if Janus was pre-initialized during push notification
      final preInitData = await storage.getData('janus_pre_initialized');
      bool janusAlreadyReady = false;
      
      if (preInitData != null) {
        final preInitTime = preInitData['timestamp'] ?? 0;
        final now = DateTime.now().millisecondsSinceEpoch;
        // If pre-initialized within last 5 minutes and for same call
        if (now - preInitTime < 300000 && preInitData['call_id'] == callId) {
          janusAlreadyReady = await janusService.isHealthy();
          if (kDebugMode) print('✅ Janus already pre-initialized and healthy');
        }
      }
      
      if (!janusAlreadyReady) {
        // Step 1: Initialize Janus connection (fallback)
        if (kDebugMode) print('🔄 Initializing Janus for background call...');
        await janusService.initialize();
        await janusService.register();
        
        // Step 2: Wait for SIP registration to complete
        await Future.delayed(const Duration(seconds: 3));
      } else {
        if (kDebugMode) print('⚡ Skipping Janus init - already ready from pre-initialization');
      }
      
      // Step 3: Send "ready" signal to server with call acceptance
      if (kDebugMode) print('📡 Sending ready signal to server...');
      await _sendReadySignal(callId);
      
      // Step 4: Navigate to call screen and wait for incoming call
      NavigationService.navigateTo(const OngoingCallPage());
      if (kDebugMode) print('⏳ Ready - waiting for incoming call from Janus...');
      
      // Clean up pre-init data
      await storage.removeData('janus_pre_initialized');
      
    } catch (e) {
      if (kDebugMode) print('❌ Error initializing for incoming call: $e');
      rethrow;
    }
  }

  /// Handle call acceptance when app is already running
  Future<void> _acceptCallNormal(String callId) async {
    // Send acceptance to server immediately
    await callResponseService.acceptCall(callId);
    
    // Initialize Janus if needed
    if (janusService.session == null) {
      if (kDebugMode) print('🔄 Initializing Janus for incoming call...');
      await janusService.initialize();
      await janusService.register();
      await Future.delayed(const Duration(seconds: 2));
    }

    // Navigate to ongoing call screen
    NavigationService.navigateTo(const OngoingCallPage());
    if (kDebugMode) print('⏳ Waiting for call from Janus...');
  }

  /// Send ready signal to server indicating app is initialized and ready
  Future<void> _sendReadySignal(String callId) async {
    try {
      final callData = await storage.getData('pending_call_data');
      if (kDebugMode) print('📝 Pending call data: $callData');
      
      if (callData == null) {
        if (kDebugMode) print('❌ No pending call data found');
        return;
      }

      final serverCallId = callData['server_call_id'] ?? callData['call_id'] ?? callId;
      if (kDebugMode) print('📡 Using server_call_id: $serverCallId');
      
      if (serverCallId == null) {
        if (kDebugMode) print('❌ No server call ID found');
        return;
      }

      // Send both acceptance and ready signal
      if (kDebugMode) print('📤 Sending accept_ready to server...');
      final success = await apiService.respondToCall(serverCallId, 'accept_ready');
      
      if (success) {
        if (kDebugMode) print('✅ Ready signal sent - server can now bridge call');
        await storage.storeData('accepted_call_data', callData);
      } else {
        if (kDebugMode) print('❌ Failed to send ready signal to server');
        throw Exception('Failed to send ready signal');
      }
      
    } catch (e) {
      if (kDebugMode) print('❌ Error sending ready signal: $e');
      rethrow;
    }
  }

  /// Detect if app was launched from background/terminated state
  Future<bool> _detectBackgroundLaunch() async {
    try {
      // Check if Janus session exists - if not, likely from background
      final hasActiveSession = janusService.session != null && await janusService.isHealthy();
      
      // Also check timestamp of last app activity
      final lastActiveTime = await storage.getData('last_active_time') ?? 0;
      final currentTime = DateTime.now().millisecondsSinceEpoch;
      final timeDiff = currentTime - lastActiveTime;
      
      // If no active session OR more than 10 seconds since last activity
      final isFromBackground = !hasActiveSession || timeDiff > 10000;
      
      if (kDebugMode) print('📱 Background launch detection: $isFromBackground (session: $hasActiveSession, time diff: ${timeDiff}ms)');
      
      return isFromBackground;
    } catch (e) {
      if (kDebugMode) print('❌ Error detecting background launch: $e');
      return true; // Assume background launch on error
    }
  }

  Future<void> _handleCallDecline(Map<String, dynamic> callData) async {
    try {
      if (kDebugMode) print('❌ Call declined: $callData');
      
      final callId = callData['id'] ?? callData['call_id'];
      if (callId == null) {
        if (kDebugMode) print('❌ No call ID found in call data');
        return;
      }

      // Send decline to server immediately - no need to initialize Janus
      await callResponseService.declineCall(callId);
      
      await FlutterCallkitIncoming.endAllCalls();
      
    } catch (e) {
      if (kDebugMode) print('❌ Error declining call: $e');
      await FlutterCallkitIncoming.endAllCalls();
    }
  }

  Future<void> _handleCallEnd(Map<String, dynamic> callData) async {
    try {
      if (kDebugMode) print('📞 Call ended: $callData');
      
      final callId = callData['id'] ?? callData['call_id'];
      
      // End call through Janus if connected
      if (janusService.session != null) {
        await janusService.hangup();
      }
      
      // Notify server about call end
      if (callId != null) {
        await callResponseService.endCall(callId);
      }
      
      // Clean up navigation
      NavigationService.removePageByName('/OngoingCallPage');
      
    } catch (e) {
      if (kDebugMode) print('❌ Error ending call: $e');
    }
  }

  Future<void> _handleCallTimeout(Map<String, dynamic> callData) async {
    try {
      if (kDebugMode) print('⏰ Call timed out: $callData');
      
      final callId = callData['id'] ?? callData['call_id'];
      
      // Notify server that call timed out (treated as decline)
      if (callId != null) {
        await callResponseService.declineCall(callId);
      }
      
      await FlutterCallkitIncoming.endAllCalls();
    } catch (e) {
      if (kDebugMode) print('❌ Error handling timeout: $e');
    }
  }

  // Method to be called when app starts and there might be pending call actions
  Future<void> checkPendingCalls() async {
    try {
      final activeCalls = await FlutterCallkitIncoming.activeCalls();
      if (activeCalls.isNotEmpty) {
        if (kDebugMode) print('📞 Found ${activeCalls.length} active calls on startup');
        
        // Handle any active calls
        for (var call in activeCalls) {
          if (kDebugMode) print('📞 Active call: $call');
          
          // Check if call was accepted while app was terminated
          await _handleCallOnAppLaunch(call);
        }
      }

      // Also check for any pending CallKit events that happened while terminated
      await _checkPendingCallKitEvents();
      
    } catch (e) {
      if (kDebugMode) print('❌ Error checking pending calls: $e');
    }
  }

  /// Handle call that was interacted with while app was terminated
  Future<void> _handleCallOnAppLaunch(Map<String, dynamic> callData) async {
    try {
      final callId = callData['id'];
      final callState = callData['state']; // Can be 'accepted', 'declined', etc.
      
      if (kDebugMode) print('📞 Handling call on launch: $callId, state: $callState');
      
      // ASSUMPTION: If app launches and there's an active call, user pressed Accept
      // (because pressing Decline wouldn't launch the app)
      if (callState == 'accepted' || callState == 'connected' || callState == null) {
        if (kDebugMode) print('✅ App launched with active call - assuming ACCEPTED');
        await handleCallAccept(callData);
      } else if (callState == 'declined' || callState == 'ended') {
        if (kDebugMode) print('❌ Call was declined while terminated');
        await _handleCallDecline(callData);
      }
      
    } catch (e) {
      if (kDebugMode) print('❌ Error handling call on launch: $e');
    }
  }

  /// Check for pending CallKit events that occurred while app was terminated
  Future<void> _checkPendingCallKitEvents() async {
    try {
      if (kDebugMode) print('📱 Checking for pending CallKit events...');
      
      // Check if there was a call action expected but not processed
      final expectedAction = await storage.getData('expecting_call_action');
      if (expectedAction != null) {
        if (kDebugMode) print('📞 Found expected call action that wasn\'t processed: $expectedAction');
        
        // The call action might have been missed - check if we should process it
        final timestamp = expectedAction['timestamp'] ?? 0;
        final now = DateTime.now().millisecondsSinceEpoch;
        
        // If less than 60 seconds ago, assume user accepted (app launched means they pressed Accept)
        if (now - timestamp < 60000) {
          if (kDebugMode) print('⏰ Recent call action detected - app launched, assuming ACCEPTED');
          
          // Create fake call data and process as acceptance
          final fakeCallData = {
            'id': expectedAction['call_id'],
            'call_id': expectedAction['call_id'],
            'server_call_id': expectedAction['server_call_id']
          };
          
          // Process as if user accepted the call
          await handleCallAccept(fakeCallData);
        }
        
        // Clear the expected action
        await storage.removeData('expecting_call_action');
      }
      
    } catch (e) {
      if (kDebugMode) print('❌ Error checking pending events: $e');
    }
  }
}