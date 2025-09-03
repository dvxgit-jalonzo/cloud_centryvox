import 'package:flutter/foundation.dart';
import 'api_service.dart';
import 'storage_controller.dart';

class CallResponseService {
  static final CallResponseService _instance = CallResponseService._internal();
  factory CallResponseService() => _instance;
  CallResponseService._internal();

  final StorageController storage = StorageController();
  final ApiService apiService = ApiService();

  Future<void> acceptCall(String callId) async {
    try {
      final callData = await storage.getData('pending_call_data');
      if (callData == null) {
        if (kDebugMode) print('❌ No pending call data found');
        return;
      }

      final serverCallId = callData['server_call_id'];
      if (serverCallId == null) {
        if (kDebugMode) print('❌ No server call ID found');
        return;
      }

      // Send acceptance to server
      final success = await apiService.respondToCall(serverCallId, 'accept');
      
      if (success) {
        if (kDebugMode) print('✅ Call acceptance sent to server');
        // Store that we accepted this call
        await storage.storeData('accepted_call_data', callData);
      } else {
        if (kDebugMode) print('❌ Failed to send call acceptance to server');
        throw Exception('Failed to accept call on server');
      }
      
    } catch (e) {
      if (kDebugMode) print('❌ Error accepting call: $e');
      rethrow;
    }
  }

  Future<void> declineCall(String callId) async {
    try {
      final callData = await storage.getData('pending_call_data');
      if (callData == null) {
        if (kDebugMode) print('❌ No pending call data found');
        return;
      }

      final serverCallId = callData['server_call_id'];
      if (serverCallId == null) {
        if (kDebugMode) print('❌ No server call ID found');
        return;
      }

      // Send decline to server
      final success = await apiService.respondToCall(serverCallId, 'decline');
      
      if (success) {
        if (kDebugMode) print('✅ Call decline sent to server');
      } else {
        if (kDebugMode) print('❌ Failed to send call decline to server');
      }

      // Clean up pending call data
      await storage.removeData('pending_call_data');
      
    } catch (e) {
      if (kDebugMode) print('❌ Error declining call: $e');
      // Even if server communication fails, clean up local data
      await storage.removeData('pending_call_data');
    }
  }

  Future<void> endCall(String callId) async {
    try {
      final callData = await storage.getData('accepted_call_data');
      if (callData == null) {
        if (kDebugMode) print('❌ No accepted call data found');
        return;
      }

      final serverCallId = callData['server_call_id'];
      if (serverCallId != null) {
        // Send hangup to server
        await apiService.respondToCall(serverCallId, 'hangup');
        if (kDebugMode) print('✅ Call hangup sent to server');
      }

      // Clean up all call data
      await storage.removeData('pending_call_data');
      await storage.removeData('accepted_call_data');
      
    } catch (e) {
      if (kDebugMode) print('❌ Error ending call: $e');
      // Always clean up local data
      await storage.removeData('pending_call_data');
      await storage.removeData('accepted_call_data');
    }
  }

  Future<Map<String, dynamic>?> getPendingCallData() async {
    return await storage.getData('pending_call_data');
  }

  Future<Map<String, dynamic>?> getAcceptedCallData() async {
    return await storage.getData('accepted_call_data');
  }
}