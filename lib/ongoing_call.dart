import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import 'janus_service.dart';

class OngoingCallPage extends StatefulWidget {
  const OngoingCallPage({super.key});

  @override
  State<OngoingCallPage> createState() => _OngoingCallPageState();
}

class _OngoingCallPageState extends State<OngoingCallPage> {
  MicrophoneState micState = MicrophoneState.unmuted;
  SpeakerState speakerState = SpeakerState.earpiece;
  String callerName = 'Unknown';
  String callerNumber = '';

  final List<String> _dialpadKeys = const [
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    '*',
    '0',
    '#',
  ];

  @override
  void initState() {
    super.initState();
    _setInitialSpeakerMode();
    _loadCallerInfo();
  }

  Future<void> _setInitialSpeakerMode() async {
    await JanusService().earpieceMode();
    setState(() => speakerState = SpeakerState.earpiece);
  }

  Future<void> _loadCallerInfo() async {
    try {
      final pushData = await JanusService().storage.getData('push_notification_data');
      if (pushData != null) {
        setState(() {
          callerName = pushData['caller_name'] ?? 'Unknown Caller';
          callerNumber = pushData['caller_number'] ?? '';
        });
      }
    } catch (e) {
      print('Error loading caller info: $e');
    }
  }

  void _onButtonPressed(String value) {
    if (value == "hangup") {
      JanusService().hangup();
      // Navigate back to main screen
      Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
    } else {
      JanusService().sendDtmf(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return PopScope(
      canPop: false, // 🔒 Prevents back navigation
      child: Scaffold(
        backgroundColor: Colors.green[50],
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text("Ongoing Call"),
          backgroundColor: Colors.green,
        ),
        body: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: size.width * 0.15,
            vertical: size.height * 0.05,
          ),
          child: Column(
            children: [
              // Caller Information
              Container(
                padding: const EdgeInsets.all(20),
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(15),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.grey.withOpacity(0.3),
                      spreadRadius: 2,
                      blurRadius: 5,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 40,
                      backgroundColor: Colors.green,
                      child: Icon(
                        Icons.person,
                        size: 50,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 15),
                    Text(
                      callerName,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    if (callerNumber.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        callerNumber,
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'Connected',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              // Dial Pad Grid
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 1.2,
                ),
                itemCount: _dialpadKeys.length,
                itemBuilder: (context, index) {
                  final key = _dialpadKeys[index];
                  return GestureDetector(
                    onTap: () => _onButtonPressed(key),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.grey[800],
                        borderRadius: BorderRadius.circular(50),
                      ),
                      child: Center(
                        child: Text(
                          key,
                          style: TextStyle(
                            fontSize: size.width * 0.05,
                            fontWeight: FontWeight.w400,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 20),
              // Control Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  // Mic Button
                  RawMaterialButton(
                    onPressed: () {
                      setState(() {
                        if (micState == MicrophoneState.unmuted) {
                          FlutterBackgroundService().invoke('mute');
                          micState = MicrophoneState.muted;
                        } else {
                          FlutterBackgroundService().invoke('unmute');
                          micState = MicrophoneState.unmuted;
                        }
                      });
                    },
                    elevation: 2.0,
                    fillColor: Colors.grey,
                    shape: const CircleBorder(),
                    constraints: BoxConstraints.tightFor(
                      width: size.width * 0.18,
                      height: size.width * 0.18,
                    ),
                    child: Icon(
                      micState == MicrophoneState.unmuted
                          ? Icons.mic_off_rounded
                          : Icons.mic,
                      color: Colors.white,
                      size: size.width * 0.08,
                    ),
                  ),
                  // Hangup Button
                  RawMaterialButton(
                    onPressed: () => _onButtonPressed('hangup'),
                    elevation: 2.0,
                    fillColor: Colors.red,
                    shape: const CircleBorder(),
                    constraints: BoxConstraints.tightFor(
                      width: size.width * 0.18,
                      height: size.width * 0.18,
                    ),
                    child: Icon(
                      Icons.call_end,
                      color: Colors.white,
                      size: size.width * 0.08,
                    ),
                  ),
                  // Speaker Toggle Button
                  RawMaterialButton(
                    onPressed: () async {
                      final isSpeakerOn = await JanusService()
                          .checkSpeakerMode();
                      setState(() {
                        if (isSpeakerOn) {
                          JanusService().earpieceMode();
                          speakerState = SpeakerState.earpiece;
                        } else {
                          JanusService().speakerMode();
                          speakerState = SpeakerState.speaker;
                        }
                      });
                    },
                    elevation: 2.0,
                    fillColor: Colors.grey,
                    shape: const CircleBorder(),
                    constraints: BoxConstraints.tightFor(
                      width: size.width * 0.18,
                      height: size.width * 0.18,
                    ),
                    child: Icon(
                      speakerState == SpeakerState.earpiece
                          ? Icons.hearing
                          : Icons.speaker,
                      color: Colors.white,
                      size: size.width * 0.08,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum MicrophoneState { muted, unmuted }

enum SpeakerState { speaker, earpiece }
