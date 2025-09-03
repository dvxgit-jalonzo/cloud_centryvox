import 'dart:convert';

import 'package:cloud_centryvox/api_controller.dart';
import 'package:cloud_centryvox/general_configuration.dart';
import 'package:cloud_centryvox/janus_service.dart';
import 'package:cloud_centryvox/main.dart';
import 'package:cloud_centryvox/navigation_service.dart';
import 'package:cloud_centryvox/storage_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_encrypt_plus/flutter_encrypt_plus.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';

class ScanQrCodePage extends StatefulWidget {
  const ScanQrCodePage({super.key});

  @override
  State<ScanQrCodePage> createState() => _ScanQrCodePageState();
}

class _ScanQrCodePageState extends State<ScanQrCodePage> {
  bool _isScanned = false;

  @override
  void initState() {
    super.initState();
  }

  Future<bool> generateAccessToken(
    base,
    appId,
    appKey,
    username,
    password,
    storage,
  ) async {
    if (password == "?") password = "Diavox123!";
    final tokenUrl = '$base/oauth/token';
    final Map<String, String> body = {
      'grant_type': 'password',
      "client_id": appId,
      "client_secret": appKey,
      "username": username,
      "password": password,
      "scope": "",
    };

    final response = await http.post(Uri.parse(tokenUrl), body: body);

    if (response.statusCode == 200) {
      Map<String, dynamic> data = jsonDecode(response.body);
      final accessToken = data['access_token'];
      await storage.storeData("accessToken", accessToken);
      return true;
    } else {
      return false;
    }
  }

  void _onDetect(BarcodeCapture capture) async {
    if (_isScanned) return;

    final List<Barcode> barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;

    final barcode = barcodes.first;
    if (barcode.format != BarcodeFormat.qrCode) return;

    final String? encryptedCode = barcode.rawValue;
    if (encryptedCode == null || encryptedCode.isEmpty) return;

    try {
      final storage = StorageController();
      final key = GeneralConfiguration().getSalt;
      final decrypted = encrypt.decodeString(encryptedCode, key);
      Map<String, dynamic> data = jsonDecode(decrypted);

      await storage.storeData("appId", data['app_id']);
      await storage.storeData("appKey", data['app_key']);
      await storage.storeData("base", data['base']);
      await storage.storeData("reverbAppKey", data['reverb_app_key']);
      await storage.storeData("gateway", data['gateway']);
      await storage.storeData("androidHost", data['android_host']);

      debugPrint('✅ QR Code scanned and decrypted: $data');
      setState(() => _isScanned = true);

      SmartDialog.show(
        builder: (_) {
          final extensionController = TextEditingController();
          final passwordController = TextEditingController();
          String? extensionError, passwordError;

          return StatefulBuilder(
            builder: (context, setModalState) {
              Future<void> onPressed() async {
                final extension = extensionController.text.trim();
                final password = passwordController.text.trim();
                bool hasError = false;

                if (extension.isEmpty) {
                  hasError = true;
                  setModalState(
                    () => extensionError = "Mailbox number is required",
                  );
                }

                if (password.isEmpty) {
                  hasError = true;
                  setModalState(() => passwordError = "Password is required");
                }

                if (hasError) return;

                final storage = StorageController();
                final base = await ApiController().getBase();
                final appId = await ApiController().getAppId();
                final appKey = await ApiController().getAppKey();

                final isGenerated = await generateAccessToken(
                  base,
                  appId,
                  appKey,
                  extension,
                  password,
                  storage,
                );

                if (isGenerated) {
                  final accessToken = await storage.getData("accessToken");

                  final headers = {
                    'Authorization': 'Bearer $accessToken',
                    'Accept': 'application/json',
                    'Content-Type': 'application/json',
                  };

                  final route = "$base/api/mobile/mailbox_data/$extension";
                  final result = await http.get(
                    Uri.parse(route),
                    headers: headers,
                  );
                  final mailboxData = jsonDecode(result.body);
                  if (kDebugMode) print("✅ Data received: $mailboxData");

                  await storage.storeData("extensionNumber", extension);
                  await storage.storeData('is_qr_scanned', true);

                  // Update Janus registration now that we have the extension
                  await JanusService().initialize();

                  await JanusService().register(sendRegister: true);

                  SmartDialog.dismiss();

                  // Navigate to Main() with full UI
                  NavigationService.navigateTo(
                    Main(),
                    type: NavType.pushAndRemoveUntil,
                  );
                } else {
                  setModalState(() => passwordError = "Invalid credentials");
                }
              }

              return Material(
                color: Colors.transparent,
                child: Center(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.grey.shade300,
                          blurRadius: 12,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(height: 20),
                        TextField(
                          controller: extensionController,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            hintText: "Mailbox Number",
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            errorText: extensionError,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                          onChanged: (_) {
                            if (extensionError != null)
                              setModalState(() => extensionError = null);
                          },
                        ),
                        const SizedBox(height: 20),
                        TextField(
                          controller: passwordController,
                          obscureText: true,
                          keyboardType: TextInputType.text,
                          decoration: InputDecoration(
                            hintText: "Password",
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            errorText: passwordError,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                          onChanged: (_) {
                            if (passwordError != null)
                              setModalState(() => passwordError = null);
                          },
                        ),
                        const SizedBox(height: 30),
                        ElevatedButton(
                          onPressed: onPressed,
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                            backgroundColor: Colors.green.shade50,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            "Proceed",
                            style: TextStyle(color: Colors.green.shade900),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    } catch (e) {
      debugPrint('❌ Failed to decrypt QR code: $e');
      setState(() => _isScanned = false);
      SmartDialog.show(
        alignment: Alignment.center,
        clickMaskDismiss: true,
        builder: (_) => Container(
          margin: const EdgeInsets.all(50),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.question_mark_rounded, size: 60, color: Colors.red),
              SizedBox(height: 30),
              Text(
                "Failed to decrypt QR code!",
                style: TextStyle(
                  color: Colors.black87,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: NavigationService.navigatorKey,
      builder: FlutterSmartDialog.init(),
      navigatorObservers: [FlutterSmartDialog.observer],
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Scan QR Code'),
          actions: [
            ElevatedButton(
              onPressed: () {
                // Navigate to Main() with full UI
                NavigationService.navigateTo(
                  Main(),
                  type: NavType.pushAndRemoveUntil,
                );
              },
              child: Text("Close"),
            ),
          ],
        ),
        body: MobileScanner(
          controller: MobileScannerController(
            detectionSpeed: DetectionSpeed.normal,
            facing: CameraFacing.back,
          ),
          onDetect: _onDetect,
        ),
      ),
    );
  }
}
