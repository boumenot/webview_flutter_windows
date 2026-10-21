/// A WebView2 implementation of webview_flutter for Windows.
library;

import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'src/windows_navigation_delegate.dart';
import 'src/windows_webview_api.dart';
import 'src/windows_webview_controller.dart';
import 'src/windows_webview_cookie_manager.dart';
import 'src/windows_webview_widget.dart';

export 'src/windows_navigation_delegate.dart';
export 'src/windows_webview_controller.dart';
export 'src/windows_webview_cookie_manager.dart';
export 'src/windows_webview_widget.dart';

/// The Windows implementation of [WebViewPlatform].
class WindowsWebViewPlatform extends WebViewPlatform {
  /// Initializes shared browser storage and returns the WebView2 runtime version.
  ///
  /// Call before using a controller or cookie manager to select an absolute
  /// [userDataFolder]. Omit it to keep the default or previously selected folder.
  /// Selecting a different folder after initialization starts fails explicitly.
  static Future<String> initializeEnvironment({String? userDataFolder}) async {
    return (await WindowsWebViewApi.invoke<String>('initializeEnvironment', <String, Object?>{
      'userDataFolder': ?userDataFolder,
    }))!;
  }

  /// Registers this implementation as the current web view platform.
  static void registerWith() {
    WebViewPlatform.instance = WindowsWebViewPlatform();
  }

  @override
  WindowsWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => WindowsWebViewController(params);

  @override
  WindowsNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => WindowsNavigationDelegate(params);

  @override
  WindowsWebViewWidget createPlatformWebViewWidget(PlatformWebViewWidgetCreationParams params) =>
      WindowsWebViewWidget(params);

  @override
  WindowsWebViewCookieManager createPlatformCookieManager(
    PlatformWebViewCookieManagerCreationParams params,
  ) => WindowsWebViewCookieManager(params);
}
