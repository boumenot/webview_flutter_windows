import 'package:flutter/services.dart';

/// The shared native connection for controllers and the cookie manager.
abstract final class WindowsWebViewApi {
  static const MethodChannel _channel = MethodChannel('plugins.flutter.io/webview_flutter_windows');
  static Future<void>? _initialization;
  static bool _initialized = false;

  static Future<void> _initialize() async {
    await _channel.invokeMethod<void>('initialize');
    _initialized = true;
  }

  /// Sends a command after releasing resources from the previous Dart isolate.
  static Future<T?> invoke<T>(String method, [Object? arguments]) async {
    if (!_initialized) {
      await (_initialization ??= _initialize());
    }
    return _channel.invokeMethod<T>(method, arguments);
  }
}
