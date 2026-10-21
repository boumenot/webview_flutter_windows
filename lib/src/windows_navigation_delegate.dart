import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// Navigation callbacks for a Windows WebView2 instance.
class WindowsNavigationDelegate extends PlatformNavigationDelegate {
  /// Creates a Windows navigation delegate.
  WindowsNavigationDelegate(super.params) : super.implementation();

  /// The page-started callback.
  PageEventCallback? onPageStarted;

  /// The page-finished callback.
  PageEventCallback? onPageFinished;

  /// The loading-progress callback. WebView2 reports only 0 and 100.
  ProgressCallback? onProgress;

  /// The resource-error callback.
  WebResourceErrorCallback? onWebResourceError;

  /// The URL-change callback.
  UrlChangeCallback? onUrlChange;

  /// The HTTP-error callback.
  HttpResponseErrorCallback? onHttpError;

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback onNavigationRequest) async {
    throw UnsupportedError(
      'WebView2 navigation-starting events cannot be deferred while Dart decides '
      'whether to navigate. Navigation request callbacks are not supported.',
    );
  }

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {
    this.onPageStarted = onPageStarted;
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {
    this.onPageFinished = onPageFinished;
  }

  @override
  Future<void> setOnProgress(ProgressCallback onProgress) async {
    this.onProgress = onProgress;
  }

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback onWebResourceError) async {
    this.onWebResourceError = onWebResourceError;
  }

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async {
    this.onUrlChange = onUrlChange;
  }

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback onHttpError) async {
    this.onHttpError = onHttpError;
  }
}
