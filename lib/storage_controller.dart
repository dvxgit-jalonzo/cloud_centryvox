import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StorageController {
  // Singleton instance
  static final StorageController _instance = StorageController._internal();

  // Private constructor
  StorageController._internal();

  // Factory constructor to return the same instance every time
  factory StorageController() {
    return _instance;
  }

  Future<void> storeData(String key, dynamic value) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();

    if (value is String) {
      await prefs.setString(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    } else if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is double) {
      await prefs.setDouble(key, value);
    } else if (value is List<String>) {
      await prefs.setStringList(key, value);
    } else {
      throw ArgumentError("Unsupported type for SharedPreferences");
    }
  }

  Future<dynamic> getData(String key) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if (!prefs.containsKey(key)) {
      return null;
    }
    return prefs.get(key);
  }

  Future<void> removeData(dynamic key) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    await prefs.remove(key);
  }

  Future<void> clearStorage() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    await prefs.clear();
    await prefs.reload();
    debugPrint("🔄 Local storage cleared.");
  }
}
