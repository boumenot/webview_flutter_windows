import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/webview_flutter_windows');
  const events = MethodChannel('plugins.flutter.io/webview_flutter_windows/7');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late WindowsWebViewController controller;
  Completer<int>? creation;
  var scriptResult = '42';
  PlatformException? scriptError;
  var widgetOwnsController = false;

  Future<Object?> sendEvent(String method, Object? arguments) async {
    final response = Completer<ByteData?>();
    await messenger.handlePlatformMessage(
      events.name,
      events.codec.encodeMethodCall(MethodCall(method, arguments)),
      response.complete,
    );
    final ByteData? data = await response.future;
    return data == null ? null : events.codec.decodeEnvelope(data);
  }

  setUp(() {
    calls = <MethodCall>[];
    creation = null;
    widgetOwnsController = false;
    scriptResult = '42';
    scriptError = null;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'initialize') {
        return null;
      }
      calls.add(call);
      switch (call.method) {
        case 'initializeEnvironment':
          return '155.0.0.0';
        case 'create':
          return creation == null ? 7 : creation!.future;
        case 'executeScript':
          if (scriptError != null) {
            throw scriptError!;
          }
          return scriptResult;
        case 'addScript':
          return 'script-1';
        case 'clearCookies':
          return true;
        case 'canGoBack':
          return true;
        case 'canGoForward':
          return false;
        default:
          return null;
      }
    });
    WindowsWebViewPlatform.registerWith();
    controller = WindowsWebViewController(const PlatformWebViewControllerCreationParams());
  });

  tearDown(() async {
    if (!widgetOwnsController) {
      await controller.dispose();
    }
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('selects the environment before creating a controller', () async {
    expect(
      await WindowsWebViewPlatform.initializeEnvironment(
        userDataFolder: r'C:\private\browser-profile',
      ),
      '155.0.0.0',
    );
    await controller.loadHtmlString('<p>Hello</p>');
    expect(calls.first.method, 'initializeEnvironment');
    expect(calls.first.arguments, <String, Object?>{
      'userDataFolder': r'C:\private\browser-profile',
    });
    expect(calls.map((call) => call.method), <String>[
      'initializeEnvironment',
      'create',
      'loadHtmlString',
    ]);
  });

  test('surfaces environment configuration failures without creating a view', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      throw PlatformException(code: 'environmentAlreadyInitialized');
    });
    await expectLater(
      WindowsWebViewPlatform.initializeEnvironment(userDataFolder: r'C:\other'),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'environmentAlreadyInitialized',
        ),
      ),
    );
    expect(calls.map((call) => call.method), <String>['initializeEnvironment']);
  });

  test('waits for native initialization before loading', () async {
    creation = Completer<int>();
    final Future<void> loading = controller.loadRequest(
      LoadRequestParams(uri: Uri.parse('https://flutter.dev')),
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((MethodCall call) => call.method), <String>['create']);
    creation!.complete(7);
    await loading;
    expect(calls.last.method, 'loadRequest');
    expect(calls.last.arguments, <String, Object?>{
      'id': 7,
      'url': 'https://flutter.dev',
      'method': 'GET',
      'headers': <String, String>{},
      'body': null,
    });
  });

  test('preserves POST bodies and headers', () async {
    await controller.loadRequest(
      LoadRequestParams(
        uri: Uri.parse('https://example.com'),
        method: LoadRequestMethod.post,
        headers: const <String, String>{'Content-Type': 'application/octet-stream'},
        body: Uint8List.fromList(<int>[0, 128, 255]),
      ),
    );
    final arguments = calls.last.arguments! as Map<Object?, Object?>;
    expect(arguments['method'], 'POST');
    expect(arguments['body'], <int>[0, 128, 255]);
    expect(arguments['headers'], <String, String>{'Content-Type': 'application/octet-stream'});
  });

  test('rejects URLs without a scheme and header injection', () async {
    await expectLater(
      controller.loadRequest(LoadRequestParams(uri: Uri.parse('relative'))),
      throwsArgumentError,
    );
    await expectLater(
      controller.loadRequest(
        LoadRequestParams(
          uri: Uri.parse('https://example.com'),
          headers: const <String, String>{'X-Test': 'ok\r\nInjected: yes'},
        ),
      ),
      throwsArgumentError,
    );
    expect(calls, isEmpty);
  });

  test('reports initialization failures to the caller', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      throw PlatformException(code: 'webview2Unavailable', message: 'Install WebView2.');
    });
    await expectLater(
      controller.loadHtmlString('<p>Hello</p>'),
      throwsA(
        isA<PlatformException>().having(
          (PlatformException error) => error.code,
          'code',
          'webview2Unavailable',
        ),
      ),
    );
    await controller.dispose();
  });

  test('rejects navigation veto callbacks instead of silently ignoring them', () async {
    final delegate = WindowsNavigationDelegate(const PlatformNavigationDelegateCreationParams());
    await expectLater(
      delegate.setOnNavigationRequest((NavigationRequest request) => NavigationDecision.prevent),
      throwsUnsupportedError,
    );
  });

  test('routes navigation events and native errors', () async {
    final seen = <String>[];
    WebResourceError? error;
    final delegate = WindowsNavigationDelegate(const PlatformNavigationDelegateCreationParams());
    await delegate.setOnPageStarted((String url) => seen.add('start:$url'));
    await delegate.setOnPageFinished((String url) => seen.add('finish:$url'));
    await delegate.setOnProgress((int progress) => seen.add('progress:$progress'));
    await delegate.setOnUrlChange((UrlChange change) => seen.add('url:${change.url}'));
    await delegate.setOnWebResourceError((WebResourceError value) => error = value);
    await controller.setPlatformNavigationDelegate(delegate);
    await sendEvent('pageStarted', 'https://example.com');
    await sendEvent('urlChanged', 'https://example.com/redirect');
    await sendEvent('pageFinished', 'https://example.com/redirect');
    await sendEvent('webResourceError', <String, Object?>{
      'errorCode': 7,
      'description': 'Connection failed',
      'url': 'https://example.com/redirect',
    });
    expect(seen, <String>[
      'start:https://example.com',
      'progress:0',
      'url:https://example.com/redirect',
      'finish:https://example.com/redirect',
      'progress:100',
    ]);
    expect(error!.errorCode, 7);
    expect(error!.isForMainFrame, isTrue);
  });

  test('decodes JavaScript values and surfaces exceptions', () async {
    expect(await controller.runJavaScriptReturningResult('6 * 7'), 42);
    scriptResult = 'false';
    expect(await controller.runJavaScriptReturningResult('false'), false);
    scriptResult = r'"a quoted \"string\""';
    expect(
      await controller.runJavaScriptReturningResult(r'"a quoted \"string\""'),
      'a quoted "string"',
    );
    scriptError = PlatformException(code: 'javaScriptError', message: 'missing is not defined');
    await expectLater(controller.runJavaScript('missing()'), throwsA(isA<PlatformException>()));
    scriptError = null;
    scriptResult = 'null';
    await expectLater(
      controller.runJavaScriptReturningResult('null'),
      throwsA(isA<PlatformException>()),
    );
  });

  test('JavaScript channels validate names and route messages', () async {
    String? received;
    await controller.addJavaScriptChannel(
      JavaScriptChannelParams(
        name: 'Messages',
        onMessageReceived: (JavaScriptMessage message) {
          received = message.message;
        },
      ),
    );
    await sendEvent(
      'webMessage',
      jsonEncode(<String, String>{'channel': 'Messages', 'message': 'hello'}),
    );
    expect(received, 'hello');
    await controller.removeJavaScriptChannel('Messages');
    received = null;
    await sendEvent('webMessage', '{"channel":"Messages","message":"ignored"}');
    expect(received, isNull);
    await expectLater(
      controller.addJavaScriptChannel(
        JavaScriptChannelParams(
          name: 'bad-name',
          onMessageReceived: (JavaScriptMessage message) {},
        ),
      ),
      throwsArgumentError,
    );
  });

  test('cookie manager works before a widget is created', () async {
    final manager = WindowsWebViewCookieManager(const PlatformWebViewCookieManagerCreationParams());
    await manager.setCookie(
      const WebViewCookie(name: 'session', value: 'abc', domain: 'example.com'),
    );
    expect(calls.last.method, 'setCookie');
    expect(calls.last.arguments, <String, String>{
      'name': 'session',
      'value': 'abc',
      'domain': 'example.com',
      'path': '/',
    });
    expect(await manager.clearCookies(), isTrue);
  });

  test('disposal is idempotent and rejects later operations', () async {
    await controller.loadHtmlString('<p>Hello</p>');
    await controller.dispose();
    await controller.dispose();
    expect(calls.where((MethodCall call) => call.method == 'dispose'), hasLength(1));
    await expectLater(controller.reload(), throwsStateError);
  });

  testWidgets('widget updates native bounds and disposes its view', (WidgetTester tester) async {
    widgetOwnsController = true;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 320,
            height: 200,
            child: Builder(
              builder: (BuildContext context) {
                return WindowsWebViewWidget(
                  PlatformWebViewWidgetCreationParams(controller: controller),
                ).build(context);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(calls.where((MethodCall call) => call.method == 'setBounds'), isNotEmpty);
    final arguments =
        calls.lastWhere((MethodCall call) => call.method == 'setBounds').arguments!
            as Map<Object?, Object?>;
    expect(arguments['width'], 640.0);
    expect(arguments['height'], 400.0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(calls.last.method, 'dispose');
    await controller.dispose();
  });

  testWidgets('replacing a controller disposes the old view and positions the new view', (
    WidgetTester tester,
  ) async {
    widgetOwnsController = true;
    final replacement = WindowsWebViewController(const PlatformWebViewControllerCreationParams());
    Widget build(WindowsWebViewController value) => Directionality(
      textDirection: TextDirection.ltr,
      child: Builder(
        builder: (BuildContext context) {
          return WindowsWebViewWidget(
            PlatformWebViewWidgetCreationParams(controller: value),
          ).build(context);
        },
      ),
    );
    await tester.pumpWidget(build(controller));
    await tester.pump();
    calls.clear();
    await tester.pumpWidget(build(replacement));
    await tester.pump();
    expect(
      calls.map((MethodCall call) => call.method),
      containsAll(<String>['dispose', 'create', 'setBounds']),
    );
    await expectLater(controller.reload(), throwsStateError);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await replacement.dispose();
  });

  testWidgets('hiding retains the viewport and disables the native window', (
    WidgetTester tester,
  ) async {
    widgetOwnsController = true;
    Widget build(bool offstage) => Directionality(
      textDirection: TextDirection.ltr,
      child: Offstage(
        offstage: offstage,
        child: Builder(
          builder: (BuildContext context) {
            return WindowsWebViewWidget(
              PlatformWebViewWidgetCreationParams(controller: controller),
            ).build(context);
          },
        ),
      ),
    );
    await tester.pumpWidget(build(false));
    await tester.pump();
    final visibleBounds =
        calls.lastWhere((MethodCall call) => call.method == 'setBounds').arguments!
            as Map<Object?, Object?>;
    calls.clear();
    await tester.pumpWidget(build(true));
    await tester.pump();
    final bounds =
        calls.lastWhere((MethodCall call) => call.method == 'setBounds').arguments!
            as Map<Object?, Object?>;
    expect(bounds['width'], visibleBounds['width']);
    expect(bounds['height'], visibleBounds['height']);
    expect(bounds['visible'], isFalse);
    expect(calls.any((call) => call.method == 'dispose'), isFalse);
    await tester.pumpWidget(build(false));
    await tester.pump();
    expect(
      (calls.lastWhere((call) => call.method == 'setBounds').arguments!
          as Map<Object?, Object?>)['visible'],
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await controller.dispose();
  });

  testWidgets('transfers keyboard focus into and out of the native web view', (
    WidgetTester tester,
  ) async {
    widgetOwnsController = true;
    final before = FocusNode();
    final after = FocusNode();
    addTearDown(before.dispose);
    addTearDown(after.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: FocusTraversalGroup(
          child: Column(
            children: <Widget>[
              Focus(focusNode: before, child: const SizedBox(height: 10)),
              Expanded(
                child: Builder(
                  builder: (BuildContext context) {
                    return WindowsWebViewWidget(
                      PlatformWebViewWidgetCreationParams(controller: controller),
                    ).build(context);
                  },
                ),
              ),
              Focus(focusNode: after, child: const SizedBox(height: 10)),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    before.requestFocus();
    await tester.pump();
    before.nextFocus();
    await tester.pump();
    expect(calls.where((MethodCall call) => call.method == 'focus'), isNotEmpty);
    await sendEvent('moveFocus', false);
    await tester.pump();
    expect(after.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await controller.dispose();
  });
}
