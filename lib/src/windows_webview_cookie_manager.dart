import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'windows_webview_api.dart';

/// Manages cookies in the shared WebView2 profile.
class WindowsWebViewCookieManager extends PlatformWebViewCookieManager {
  /// Creates a Windows cookie manager.
  WindowsWebViewCookieManager(super.params) : super.implementation();

  @override
  Future<bool> clearCookies() async => (await WindowsWebViewApi.invoke<bool>('clearCookies'))!;

  @override
  Future<void> setCookie(WebViewCookie cookie) =>
      WindowsWebViewApi.invoke<void>('setCookie', <String, String>{
        'name': cookie.name,
        'value': cookie.value,
        'domain': cookie.domain,
        'path': cookie.path,
      });

  @override
  Future<List<WebViewCookie>> getCookies(Uri url) async {
    final List<Object?> cookies = (await WindowsWebViewApi.invoke<List<Object?>>(
      'getCookies',
      <String, String>{'url': url.toString()},
    ))!;
    return cookies.map((Object? value) {
      final cookie = value! as Map<Object?, Object?>;
      return WebViewCookie(
        name: cookie['name']! as String,
        value: cookie['value']! as String,
        domain: cookie['domain']! as String,
        path: cookie['path']! as String,
      );
    }).toList();
  }
}
