import 'package:flutter/material.dart';

enum NavType { push, pushReplacement, pushAndRemoveUntil }

class NavigationService {
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static Future<void> navigateTo(
    Widget page, {
    NavType type = NavType.push,
    String? routeName,
  }) async {
    final state = navigatorKey.currentState;
    if (state == null) return; // Navigator not ready yet

    final defaultName = '/${page.runtimeType}';
    final targetName = routeName ?? defaultName;

    // Check if the route is already in the stack
    bool existsInStack = false;
    state.popUntil((route) {
      if (route.settings.name == targetName) {
        existsInStack = true;
      }
      return true;
    });

    if (existsInStack) {
      state.popUntil((route) => route.settings.name == targetName);
      return;
    }

    // Create route
    final route = MaterialPageRoute(
      builder: (_) => page,
      settings: RouteSettings(name: targetName),
    );

    switch (type) {
      case NavType.push:
        state.push(route);
        break;
      case NavType.pushReplacement:
        state.pushReplacement(route);
        break;
      case NavType.pushAndRemoveUntil:
        state.pushAndRemoveUntil(route, (r) => false);
        break;
    }
  }

  static void removePageByName(String routeName) {
    final state = navigatorKey.currentState;
    if (state == null) return;

    state.popUntil((route) {
      if (route.settings.name == routeName) {
        state.removeRoute(route);
      }
      return true;
    });
  }

  static void popTo(String routeName) {
    final state = navigatorKey.currentState;
    if (state == null) return;

    state.popUntil((route) => route.settings.name == routeName);
  }
}
