import 'dart:convert';

import 'package:cloud_centryvox/storage_controller.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class ApiController {
  // Singleton instance
  static final ApiController _instance = ApiController._internal();

  // Private constructor
  ApiController._internal();

  // Factory constructor to return the same instance every time
  factory ApiController() {
    return _instance;
  }

  final StorageController _storage = StorageController();

  Future<String?> getBase() async {
    return await _storage.getData("base");
  }

  Future<String?> getAppId() async {
    return await _storage.getData("appId");
  }

  Future<String?> getAppKey() async {
    return await _storage.getData("appKey");
  }

  Future<String?> getExtensionNumber() async {
    return await _storage.getData("extensionNumber");
  }

  Future<void> populateExtensionToken() async {
    try {
      if (kDebugMode) print('🔄 populateExtensionToken: Starting...');
      
      final token = await FirebaseMessaging.instance.getToken();
      if (kDebugMode) print('📱 FCM Token: ${token?.substring(0, 20)}...');
      
      final accessToken = await _storage.getData("accessToken");
      if (kDebugMode) print('🔑 Access Token: ${accessToken != null ? "✅ Available" : "❌ Missing"}');
      
      final base = await _storage.getData("base");
      if (kDebugMode) print('🌐 Base URL: $base');
      
      final extensionNumber = await _storage.getData("extensionNumber");
      if (kDebugMode) print('📞 Extension: $extensionNumber');
      
      // Validate required data
      if (token == null) {
        throw Exception('FCM token is null');
      }
      if (accessToken == null) {
        throw Exception('Access token is missing');
      }
      if (base == null) {
        throw Exception('Base URL is missing');
      }
      if (extensionNumber == null) {
        throw Exception('Extension number is missing');
      }
      
      final headers = {
        'Authorization': 'Bearer $accessToken',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };
      
      final route = "$base/api/mobile/populate_mailbox_token";
      if (kDebugMode) print('🎯 API Endpoint: $route');
      
      final body = jsonEncode({
        'token': token,
        'mailbox_number': extensionNumber,
      });
      
      if (kDebugMode) print('📤 Sending request...');
      
      final response = await http.post(
        Uri.parse(route),
        headers: headers,
        body: body,
      ).timeout(const Duration(seconds: 10)); // Add timeout
      
      if (kDebugMode) print('📥 Response: ${response.statusCode} - ${response.body}');

      if (response.statusCode != 200) {
        throw Exception('Failed to update token. Status: ${response.statusCode}, Body: ${response.body}');
      }
      
      if (kDebugMode) print('✅ populateExtensionToken: Success!');
      
    } catch (e) {
      if (kDebugMode) print('❌ populateExtensionToken: Error - $e');
      rethrow;
    }
  }
}
