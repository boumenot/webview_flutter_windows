import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:meta/meta.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'windows_navigation_delegate.dart';
import 'windows_webview_api.dart';

/// Controls a Windows WebView2 instance.
///
/// Creation is lazy and all operations wait for initialization. A controller is
/// disposed when its widget is removed. Controllers that are never attached to a
/// widget must be explicitly disposed using [dispose].
class WindowsWebViewController extends PlatformWebViewController {
  /// Creates a Windows web view controller.
  WindowsWebViewController(super.params) : super.implementation();

  Future<int>? _creation;
  Future<void>? _disposal;
  bool _disposed = false;
  MethodChannel? _events;
  WindowsNavigationDelegate? _delegate;
  final Map<String, JavaScriptChannelParams> _javaScriptChannels =
      <String, JavaScriptChannelParams>{};
  final Map<String, String> _scripts = <String, String>{};
  VoidCallback? _onFocus;
  ValueChanged<bool>? _onMoveFocus;

  Future<int> _initialize() {
    if (_disposed) {
      throw StateError('This Windows web view controller has been disposed.');
    }
    return _creation ??= _create();
  }

  Future<int> _create() async {
    final int id = (await WindowsWebViewApi.invoke<int>('create'))!;
    _events = MethodChannel('plugins.flutter.io/webview_flutter_windows/$id')
      ..setMethodCallHandler(_handleEvent);
    return id;
  }

  Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]) async {
    final int id = await _initialize();
    if (_disposed) {
      throw StateError('This Windows web view controller has been disposed.');
    }
    return WindowsWebViewApi.invoke<T>(method, <String, Object?>{'id': id, ...arguments});
  }

  Future<Object?> _handleEvent(MethodCall call) async {
    if (_disposed) {
      return null;
    }
    switch (call.method) {
      case 'pageStarted':
        _delegate?.onPageStarted?.call(call.arguments! as String);
        _delegate?.onProgress?.call(0);
      case 'pageFinished':
        _delegate?.onPageFinished?.call(call.arguments! as String);
        _delegate?.onProgress?.call(100);
      case 'urlChanged':
        _delegate?.onUrlChange?.call(UrlChange(url: call.arguments! as String));
      case 'webResourceError':
        final arguments = call.arguments! as Map<Object?, Object?>;
        _delegate?.onWebResourceError?.call(
          WebResourceError(
            errorCode: arguments['errorCode']! as int,
            description: arguments['description']! as String,
            url: arguments['url']! as String,
            isForMainFrame: true,
          ),
        );
      case 'httpError':
        final arguments = call.arguments! as Map<Object?, Object?>;
        _delegate?.onHttpError?.call(
          HttpResponseError(
            response: WebResourceResponse(
              uri: Uri.parse(arguments['url']! as String),
              statusCode: arguments['statusCode']! as int,
            ),
          ),
        );
      case 'webMessage':
        final Object? message = jsonDecode(call.arguments! as String);
        if (message case {'channel': final String name, 'message': final String value}) {
          _javaScriptChannels[name]?.onMessageReceived(JavaScriptMessage(message: value));
        }
      case 'gotFocus':
        _onFocus?.call();
      case 'moveFocus':
        _onMoveFocus?.call(call.arguments! as bool);
      default:
        throw MissingPluginException('Unknown WebView2 event: ${call.method}');
    }
    return null;
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    if (!params.uri.hasScheme) {
      throw ArgumentError.value(params.uri, 'uri', 'Must have a scheme.');
    }
    for (final MapEntry<String, String> header in params.headers.entries) {
      if (!RegExp(r"^[!#$%&'*+\-.^_`|~0-9a-zA-Z]+$").hasMatch(header.key) ||
          header.value.contains(RegExp(r'[\r\n\x00]'))) {
        throw ArgumentError.value(header, 'headers', 'Invalid HTTP header.');
      }
    }
    await _invoke<void>('loadRequest', <String, Object?>{
      'url': params.uri.toString(),
      'method': params.method == LoadRequestMethod.get ? 'GET' : 'POST',
      'headers': params.headers,
      'body': params.body,
    });
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    if (baseUrl != null) {
      throw UnsupportedError(
        'WebView2 NavigateToString does not support a base URL. '
        'Include a <base href="..."> element in the HTML instead.',
      );
    }
    await _invoke<void>('loadHtmlString', <String, Object?>{'html': html});
  }

  @override
  Future<void> loadFile(String absoluteFilePath) async {
    if (!File(absoluteFilePath).isAbsolute || !File(absoluteFilePath).existsSync()) {
      throw ArgumentError.value(
        absoluteFilePath,
        'absoluteFilePath',
        'Must be an existing absolute file.',
      );
    }
    await loadRequest(LoadRequestParams(uri: Uri.file(absoluteFilePath, windows: true)));
  }

  @override
  Future<void> loadFlutterAsset(String key) async {
    // Resolve through the asset bundle first so missing assets fail explicitly.
    await rootBundle.load(key);
    await loadFile('${File(Platform.resolvedExecutable).parent.path}\\data\\flutter_assets\\$key');
  }

  @override
  Future<String?> currentUrl() => _invoke<String>('currentUrl');

  @override
  Future<bool> canGoBack() async => (await _invoke<bool>('canGoBack'))!;

  @override
  Future<bool> canGoForward() async => (await _invoke<bool>('canGoForward'))!;

  @override
  Future<void> goBack() async => _invoke<void>('goBack');

  @override
  Future<void> goForward() async => _invoke<void>('goForward');

  @override
  Future<void> reload() async => _invoke<void>('reload');

  @override
  Future<void> clearCache() async => _invoke<void>('clearCache');

  @override
  Future<void> clearLocalStorage() async => _invoke<void>('clearLocalStorage');

  @override
  Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate handler) async {
    if (handler is! WindowsNavigationDelegate) {
      throw ArgumentError.value(handler, 'handler', 'Must be a WindowsNavigationDelegate.');
    }
    _delegate = handler;
    await _initialize();
  }

  Future<Object?> _evaluate(String source) async {
    final String result = (await _invoke<String>('executeScript', <String, Object?>{
      'script': source,
    }))!;
    return jsonDecode(result);
  }

  @override
  Future<void> runJavaScript(String javaScript) async {
    await _invoke<String>('executeScript', <String, Object?>{'script': javaScript});
  }

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    final Object? result = await _evaluate(javaScript);
    if (result == null) {
      throw PlatformException(
        code: 'javaScriptResultTypeIsUnsupported',
        message: 'The JavaScript result was null or undefined.',
      );
    }
    return result;
  }

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams javaScriptChannelParams) async {
    final String name = javaScriptChannelParams.name;
    if (!RegExp(r'^[a-zA-Z_$][a-zA-Z0-9_$]*$').hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'Must be a JavaScript identifier.');
    }
    if (_javaScriptChannels.containsKey(name)) {
      throw ArgumentError.value(name, 'name', 'A channel with this name already exists.');
    }
    final String key = jsonEncode(name);
    final script =
        '''
window[$key] = {postMessage: function(message) {
  window.chrome.webview.postMessage({channel: $key, message: String(message)});
}};
''';
    final String scriptId = (await _invoke<String>('addScript', <String, Object?>{
      'script': script,
    }))!;
    _scripts[name] = scriptId;
    _javaScriptChannels[name] = javaScriptChannelParams;
    await runJavaScript(script);
  }

  @override
  Future<void> removeJavaScriptChannel(String javaScriptChannelName) async {
    final String? scriptId = _scripts[javaScriptChannelName];
    if (scriptId == null) {
      return;
    }
    await _invoke<void>('removeScript', <String, Object?>{'scriptId': scriptId});
    await runJavaScript('delete window[${jsonEncode(javaScriptChannelName)}]');
    _scripts.remove(javaScriptChannelName);
    _javaScriptChannels.remove(javaScriptChannelName);
  }

  @override
  Future<String?> getTitle() => _invoke<String>('getTitle');

  @override
  Future<void> scrollTo(int x, int y) => runJavaScript('window.scrollTo($x, $y)');

  @override
  Future<void> scrollBy(int x, int y) => runJavaScript('window.scrollBy($x, $y)');

  @override
  Future<Offset> getScrollPosition() async {
    final result =
        await runJavaScriptReturningResult('[window.scrollX, window.scrollY]') as List<Object?>;
    return Offset((result[0]! as num).toDouble(), (result[1]! as num).toDouble());
  }

  @override
  Future<void> enableZoom(bool enabled) async {
    await _invoke<void>('enableZoom', <String, Object?>{'enabled': enabled});
  }

  @override
  Future<void> setBackgroundColor(Color color) async {
    await _invoke<void>('setBackgroundColor', <String, Object?>{'color': color.toARGB32()});
  }

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {
    await _invoke<void>('setJavaScriptMode', <String, Object?>{
      'enabled': javaScriptMode == JavaScriptMode.unrestricted,
    });
  }

  @override
  Future<void> setUserAgent(String? userAgent) async {
    await _invoke<void>('setUserAgent', <String, Object?>{'userAgent': userAgent});
  }

  @override
  Future<String?> getUserAgent() => _invoke<String>('getUserAgent');

  /// Connects native focus events to the owning widget.
  @internal
  void setFocusCallbacks({VoidCallback? onFocus, ValueChanged<bool>? onMoveFocus}) {
    _onFocus = onFocus;
    _onMoveFocus = onMoveFocus;
  }

  /// Transfers keyboard focus between Flutter and the native child window.
  @internal
  Future<void> setFocus(bool focused, {bool reverse = false}) async {
    await _invoke<void>('focus', <String, Object?>{'focused': focused, 'reverse': reverse});
  }

  /// Updates the native child window's physical bounds in the Flutter view.
  Future<void> setBounds(Rect bounds, {bool visible = true}) async {
    await _invoke<void>('setBounds', <String, Object?>{
      'left': bounds.left,
      'top': bounds.top,
      'width': bounds.width,
      'height': bounds.height,
      'visible': visible,
    });
  }

  /// Releases the native WebView2 controller.
  ///
  /// It is an error to use this controller again after disposal.
  Future<void> dispose() {
    _disposed = true;
    setFocusCallbacks();
    return _disposal ??= _dispose();
  }

  Future<void> _dispose() async {
    final Future<int>? creation = _creation;
    if (creation == null) {
      return;
    }
    await creation.then<void>(
      (int id) async {
        _events?.setMethodCallHandler(null);
        await WindowsWebViewApi.invoke<void>('dispose', <String, Object?>{'id': id});
      },
      onError: (Object error, StackTrace stack) {
        // Creation failures are delivered by the initiating operation. There is
        // no native instance to release when creation did not succeed.
      },
    );
    _javaScriptChannels.clear();
    _scripts.clear();
    _delegate = null;
  }
}
