import 'dart:io';

import 'package:cloud_centryvox/ongoing_call.dart';
import 'package:cloud_centryvox/storage_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:janus_client/janus_client.dart';
import 'package:uuid/uuid.dart';

import 'navigation_service.dart';

class JanusService {
  static final JanusService _instance = JanusService._internal();
  factory JanusService() => _instance;

  static bool _instanceCreated = false;

  JanusService._internal() {
    if (_instanceCreated) {
      throw Exception("🚫 Use JanusService() only once.");
    }
    _instanceCreated = true;
  }

  final storage = StorageController();
  late JanusClient janusClient;
  JanusSipPlugin? janusSipPlugin;
  JanusSession? session;
  RTCSessionDescription? rtc;

  String? androidHost;
  String? extensionNumber;
  final String password = "2241";

  /// Initialize Janus client + SIP plugin
  @pragma('vm:entry-point')
  Future<void> initialize() async {
    androidHost = await storage.getData("androidHost");
    extensionNumber = await storage.getData("extensionNumber");

    // Reset if needed
    if (session != null && !await isHealthy()) {
      await reset();
    }

    if (session != null) return; // Already initialized

    try {
      janusClient = JanusClient(
        transport: WebSocketJanusTransport(url: "ws://$androidHost:8188/janus"),
        iceServers: [
          RTCIceServer(urls: "stun:stun.l.google.com"),
          RTCIceServer(urls: "stun:stun2.l.google.com"),
          RTCIceServer(urls: "stun:stun3.l.google.com"),
          RTCIceServer(
            urls: "turn:122.3.188.98?transport=udp",
            username: "diavox",
            credential: "diavox",
          ),
        ],
        isUnifiedPlan: true,
      );

      session = await janusClient.createSession();
      janusSipPlugin = await session?.attach<JanusSipPlugin>();
      await janusSipPlugin?.initializeMediaDevices(
        mediaConstraints: {'audio': true, 'video': false},
      );
      earpieceMode();

      janusSipPlugin?.typedMessages?.listen(_handleSipEvent);

      // Set up CallKit event listener for real calls
      _setupCallKitEventListener();

      if (kDebugMode) print("✅ Janus initialized successfully");
    } catch (e, stack) {
      if (kDebugMode) print("❌ Janus init error: $e\n$stack");
      rethrow;
    }
  }

  void _handleSipEvent(event) async {
    if (kDebugMode)
      print(
        "📡 SIP Event received: ${event.event.plugindata?.data.runtimeType}",
      );

    final data = event.event.plugindata?.data;
    if (data is SipRegisteredEvent) {
      if (kDebugMode) print("✅ SIP Registered Event");
      Fluttertoast.showToast(msg: "SIP Registered");
    } else if (data is SipIncomingCallEvent) {
      if (kDebugMode)
        print(
          "📞 SIP Incoming Call Event - CRITICAL: This should trigger CallKit UI",
        );
      await janusSipPlugin?.initializeWebRTCStack();
      rtc = event.jsep;

      if (kDebugMode) print("🚀 About to call showCallkitIncoming()...");
      await showCallkitIncoming();
      if (kDebugMode) print("✅ showCallkitIncoming() completed");
    } else if (data is SipAcceptedEvent) {
      if (kDebugMode) print("✅ SIP Accepted Event");
      await janusSipPlugin?.handleRemoteJsep(event.jsep);
      NavigationService.navigateTo(const OngoingCallPage());
    } else if (data is SipHangupEvent) {
      if (kDebugMode) print("📞 SIP Hangup Event");
      earpieceMode();
      NavigationService.removePageByName('/OngoingCallPage');
    } else if (kDebugMode) {
      print("❌ Unhandled SIP event: $data");
    }
  }

  /// Set up CallKit event listener for real incoming calls from Janus
  void _setupCallKitEventListener() {
    FlutterCallkitIncoming.onEvent.listen((CallEvent? event) async {
      if (event == null) return;

      if (kDebugMode) print('📞 CallKit Event from Janus: ${event.event}');

      switch (event.event) {
        case Event.actionCallAccept:
        case Event.actionCallStart:
          if (kDebugMode) print('✅ Real call accepted from Janus');
          await _handleRealCallAccept();
          break;

        case Event.actionCallDecline:
          if (kDebugMode) print('❌ Real call declined from Janus');
          await _handleRealCallDecline();
          break;

        case Event.actionCallEnded:
          if (kDebugMode) print('📞 Real call ended from Janus');
          await _handleRealCallEnd();
          break;

        default:
          if (kDebugMode) print('🤔 Unhandled CallKit event: ${event.event}');
      }
    });
  }

  /// Handle real call acceptance from CallKit
  Future<void> _handleRealCallAccept() async {
    try {
      if (kDebugMode) print('🎯 Accepting real call via Janus SIP...');
      await accept(); // Use existing Janus accept method
      if (kDebugMode) print('✅ Real call accepted successfully');
    } catch (e) {
      if (kDebugMode) print('❌ Error accepting real call: $e');
    }
  }

  /// Handle real call decline from CallKit
  Future<void> _handleRealCallDecline() async {
    try {
      if (kDebugMode) print('🎯 Declining real call via Janus SIP...');
      await decline(); // Use existing Janus decline method
      await FlutterCallkitIncoming.endAllCalls();
      if (kDebugMode) print('✅ Real call declined successfully');
    } catch (e) {
      if (kDebugMode) print('❌ Error declining real call: $e');
    }
  }

  /// Handle real call end from CallKit
  Future<void> _handleRealCallEnd() async {
    try {
      if (kDebugMode) print('🎯 Ending real call via Janus SIP...');
      await hangup(); // Use existing Janus hangup method
      if (kDebugMode) print('✅ Real call ended successfully');
    } catch (e) {
      if (kDebugMode) print('❌ Error ending real call: $e');
    }
  }

  /// SIP Register
  Future<void> register({bool sendRegister = true}) async {
    if (kDebugMode) print('📞 SIP REGISTER: Registering with sip:$extensionNumber@$androidHost');
    
    await janusSipPlugin?.register(
      "sip:$extensionNumber@$androidHost",
      forceUdp: true,
      sendRegister: sendRegister,
      displayName: "User Name",
      rfc2543Cancel: true,
      proxy: "sip:$androidHost",
      secret: password,
    );
    
    if (kDebugMode) print('📞 SIP REGISTER: Registration request sent - waiting for events...');
  }

  /// Call a SIP number
  Future<void> call(String number) async {
    await janusSipPlugin?.initializeWebRTCStack();
    await _initializeLocalStream();
    final offer = await janusSipPlugin?.createOffer(audioRecv: true);
    await janusSipPlugin?.call("sip:$number@$androidHost", offer: offer);
  }

  /// Hang up current call
  Future<void> hangup() async {
    await janusSipPlugin?.hangup();
  }

  /// Send DTMF tones
  Future<void> sendDtmf(String number) async {
    for (var sender in await janusSipPlugin!.peerConnection!.getSenders()) {
      if (sender.track?.kind == 'audio') sender.dtmfSender.insertDTMF(number);
    }
  }

  /// Mute microphone
  Future<void> mute() async {
    for (var sender in await janusSipPlugin!.peerConnection!.getSenders()) {
      if (sender.track?.kind == 'audio') sender.track?.enabled = false;
    }
  }

  /// Unmute microphone
  Future<void> unmute() async {
    for (var sender in await janusSipPlugin!.peerConnection!.getSenders()) {
      if (sender.track?.kind == 'audio') sender.track?.enabled = true;
    }
  }

  /// Enable speaker mode
  Future<void> speakerMode() async {
    var receivers = await janusSipPlugin?.webRTCHandle?.peerConnection
        ?.getReceivers();
    receivers?.forEach((r) {
      if (r.track?.kind == 'audio') r.track?.enableSpeakerphone(true);
    });
  }

  /// Switch to earpiece
  Future<void> earpieceMode() async {
    var receivers = await janusSipPlugin?.webRTCHandle?.peerConnection
        ?.getReceivers();
    receivers?.forEach((r) {
      if (r.track?.kind == 'audio') r.track?.enableSpeakerphone(false);
    });
  }

  /// Accept incoming call
  Future<void> accept() async {
    await _initializeLocalStream();
    await janusSipPlugin?.handleRemoteJsep(rtc);
    var answer = await janusSipPlugin?.createAnswer();
    await janusSipPlugin?.accept(sessionDescription: answer);
  }

  /// Decline incoming call
  Future<void> decline() async {
    await janusSipPlugin?.decline();
  }

  /// Check if speaker is on
  Future<bool> checkSpeakerMode() async {
    const androidChannel = MethodChannel('cloud_centryvox.android.audio');
    const iosChannel = MethodChannel('cloud_centryvox.ios.audio');

    try {
      if (Platform.isIOS) {
        return await iosChannel.invokeMethod('isSpeakerOn');
      } else {
        return await androidChannel.invokeMethod('isSpeakerOn');
      }
    } catch (e) {
      if (kDebugMode) print('❌ Error checking speaker mode: $e');
      return false;
    }
  }

  /// Check if Janus session is alive
  Future<bool> isHealthy() async {
    try {
      return session != null && janusSipPlugin != null;
    } catch (e) {
      return false;
    }
  }

  Future<void> reset() async {
    try {
      session?.dispose();
      session = null;
      janusSipPlugin = null;
    } catch (e) {
      print("Error resetting Janus: $e");
    }
  }

  /// Initialize local media stream
  Future<void> _initializeLocalStream() async {
    await janusSipPlugin?.initializeMediaDevices(
      mediaConstraints: {'audio': true, 'video': false},
    );
  }

  /// Show CallKit incoming call UI for real calls
  @pragma('vm:entry-point')
  Future<void> showCallkitIncoming() async {
    try {
      if (kDebugMode) print('🔥 ENTERING showCallkitIncoming() function');

      // Get caller info from stored push notification data
      final pushData = await storage.getData('push_notification_data');
      final callerName = pushData?['caller_name'] ?? 'Test Caller';
      final callerNumber = pushData?['caller_number'] ?? '+1234567890';

      if (kDebugMode)
        print('📞 CallKit Data: Name=$callerName, Number=$callerNumber');
      if (kDebugMode) print('📦 Push data available: ${pushData != null}');

      // First try to end any existing calls to ensure clean state
      if (kDebugMode) print('🧹 Ending existing calls...');
      await FlutterCallkitIncoming.endAllCalls();
      await Future.delayed(const Duration(milliseconds: 500));

      if (kDebugMode)
        print('🚀 CALLING FlutterCallkitIncoming.showCallkitIncoming...');

      // Try a very simple CallKit call first
      await FlutterCallkitIncoming.showCallkitIncoming(
        CallKitParams(
          id: const Uuid().v4(),
          nameCaller: callerName,
          appName: 'CentVox',
          avatar: 'assets/images/icon/call_image.png',
          handle: callerNumber,
          type: 0,
          textAccept: 'Accept',
          textDecline: 'Decline',
          duration: 30000,
          headers: <String, dynamic>{'platform': 'flutter'},
          extra: <String, dynamic>{
            'caller': callerName,
            'caller_number': callerNumber,
            'is_real_call': true,
          },
          android: const AndroidParams(
            isCustomNotification: false,
            isShowFullLockedScreen: true,
            ringtonePath: '',
            backgroundColor: '#075E54',
            actionColor: '#4CAF50',
            isShowCallID: false,
          ),
          ios: IOSParams(iconName: 'CallKitLogo', ringtonePath: ''),
        ),
      );

      if (kDebugMode)
        print(
          '✅ FlutterCallkitIncoming.showCallkitIncoming completed successfully!',
        );
    } catch (e, stackTrace) {
      if (kDebugMode) {
        print('❌ CRITICAL ERROR in showCallkitIncoming: $e');
        print('📍 Stack trace: $stackTrace');
      }
      rethrow;
    }
  }
}
