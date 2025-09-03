import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'storage_controller.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  final StorageController storage = StorageController();

  /// Respond to incoming call (accept/decline/hangup/accept_ready)
  Future<bool> respondToCall(String serverCallId, String action) async {
    debugPrint('Responding to call with action: $action');
    debugPrint('Server call ID: $serverCallId');
    try {
      String status;
      switch (action) {
        case 'accept_ready':
          status = 'ready';
          break;
        case 'accept':
          status = 'accepted';
          break;
        case 'decline':
          status = 'rejected';
          break;
        case 'hangup':
          status = 'timeout';
          break;
        default:
          status = action;
      }

      final extensionNumber = await storage.getData("extensionNumber");
      final base = await storage.getData("base");
      final accessToken = await storage.getData("accessToken");
      final headers = {
        'Authorization': 'Bearer $accessToken',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };
      final route = "$base/api/mobile-call-session/$serverCallId";

      final response = await http.put(
        Uri.parse(route),
        headers: headers,
        body: jsonEncode({
          'status': status,
          'extension': extensionNumber,
          'action': action, // 'accept', 'decline', 'hangup', or 'accept_ready'
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      );

      if (response.statusCode == 200) {
        if (kDebugMode) print('✅ Call response ($action) sent successfully');
        return true;
      } else {
        if (kDebugMode) {
          print('❌ Failed to send call response: ${response.statusCode}');
        }
        return false;
      }
    } catch (e) {
      if (kDebugMode) print('❌ Error sending call response: $e');
      return false;
    }
  }
}
