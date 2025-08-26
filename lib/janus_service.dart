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

  bool headless = false;

  /// Initialize Janus client + SIP plugin
  @pragma('vm:entry-point')
  Future<void> initialize({bool headless = false}) async {
    this.headless = headless;

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
    } catch (e, stack) {
      if (kDebugMode) print("❌ Janus init error: $e\n$stack");
    }
  }

  void _handleSipEvent(event) async {
    final data = event.event.plugindata?.data;
    if (data is SipRegisteredEvent && !headless) {
      Fluttertoast.showToast(msg: "SIP Registered");
    } else if (data is SipIncomingCallEvent) {
      await janusSipPlugin?.initializeWebRTCStack();
      rtc = event.jsep;
      if (!headless) {
        showCallkitIncoming();
      } else {
        if (kDebugMode)
          print("Incoming call (headless): ${data.result?.displayname}");
      }
    } else if (data is SipAcceptedEvent) {
      await janusSipPlugin?.handleRemoteJsep(event.jsep);
      if (!headless) NavigationService.navigateTo(const OngoingCallPage());
    } else if (data is SipHangupEvent) {
      earpieceMode();
      if (!headless) NavigationService.removePageByName('/OngoingCallPage');
    } else if (kDebugMode) {
      print("❌ Unhandled SIP event: $data");
    }
  }

  /// SIP Register
  Future<void> register({bool sendRegister = true}) async {
    await janusSipPlugin?.register(
      "sip:$extensionNumber@$androidHost",
      forceUdp: true,
      sendRegister: sendRegister,
      displayName: "User Name",
      rfc2543Cancel: true,
      proxy: "sip:$androidHost",
      secret: password,
    );
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
    MediaStream? temp = await janusSipPlugin?.initializeMediaDevices(
      mediaConstraints: {'audio': true, 'video': false},
    );
  }

  /// Show CallKit incoming call UI
  @pragma('vm:entry-point')
  Future<void> showCallkitIncoming() async {
    await FlutterCallkitIncoming.showCallkitIncoming(
      CallKitParams(
        id: const Uuid().v4(),
        nameCaller: "Incoming Call",
        appName: 'CentVox',
        avatar: 'assets/images/icon/call_image.png',
        handle: 'SIP Call',
        type: 0,
        textAccept: 'Accept',
        textDecline: 'Decline',
        extra: <String, dynamic>{'caller': "SIP Caller"},
        android: const AndroidParams(
          isCustomNotification: true,
          isShowLogo: true,
          isShowFullLockedScreen: true,
          ringtonePath: 'system_ringtone_default',
          backgroundColor: '#075E54',
          actionColor: '#4CAF50',
          isShowCallID: false,
        ),
        ios: IOSParams(
          iconName: 'CallKitLogo',
          ringtonePath: 'system_ringtone_default',
        ),
      ),
    );
  }
}
