import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory profile;
  setUpAll(() async {
    profile = await Directory.systemTemp.createTemp('webview-profile-test-');
  });
  setUp(() async {
    await WindowsWebViewPlatform.initializeEnvironment(userDataFolder: profile.path);
  });
  tearDownAll(() async {
    const channel = MethodChannel('plugins.flutter.io/webview_flutter_windows');
    await channel.invokeMethod<void>('initialize');
    final waiting = Stopwatch()..start();
    while (true) {
      try {
        await profile.delete(recursive: true);
        return;
      } on FileSystemException {
        if (waiting.elapsed >= const Duration(seconds: 10)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  testWidgets('custom profile is retained and cannot change after initialization', (
    WidgetTester tester,
  ) async {
    final version = await WindowsWebViewPlatform.initializeEnvironment(
      userDataFolder: '${profile.path}\\.',
    );
    expect(version, matches(RegExp(r'^\d+\.\d+\.')));
    expect(await WindowsWebViewPlatform.initializeEnvironment(), version);
    final controller = WebViewController();
    addTearDown((controller.platform as WindowsWebViewController).dispose);
    await _loadHtml(controller, '<p>Custom profile</p>');
    expect(profile.listSync(), isNotEmpty);
    await expectLater(
      WindowsWebViewPlatform.initializeEnvironment(userDataFolder: '${profile.path}\\other'),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'environmentAlreadyInitialized',
        ),
      ),
    );
    expect(
      await controller.runJavaScriptReturningResult('document.body.textContent'),
      'Custom profile',
    );
  });

  testWidgets('invalid profile folders fail rather than selecting default storage', (
    WidgetTester tester,
  ) async {
    for (final path in [
      '',
      'relative',
      r'\root-relative',
      r'C:drive-relative',
      'C:\\bad\u0000path',
    ]) {
      await expectLater(
        WindowsWebViewPlatform.initializeEnvironment(userDataFolder: path),
        throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'invalidArgument')),
      );
    }
    const channel = MethodChannel('plugins.flutter.io/webview_flutter_windows');
    await expectLater(
      channel.invokeMethod<void>('reload', <String, Object?>{}),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.message,
          'message',
          'Missing argument: id',
        ),
      ),
    );
  });

  testWidgets('a conflicting selection cannot overtake pending initialization', (
    WidgetTester tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/webview_flutter_windows');
    await channel.invokeMethod<void>('initialize');
    final first = WindowsWebViewPlatform.initializeEnvironment(userDataFolder: profile.path);
    await expectLater(
      WindowsWebViewPlatform.initializeEnvironment(userDataFolder: '${profile.path}\\other'),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'environmentAlreadyInitialized',
        ),
      ),
    );
    expect(await first, isNotEmpty);
  });

  testWidgets('an unusable folder fails instead of falling back to default storage', (
    WidgetTester tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/webview_flutter_windows');
    await channel.invokeMethod<void>('initialize');
    final file = File('${profile.path}\\not-a-directory')..writeAsStringSync('test');
    try {
      await expectLater(
        WindowsWebViewPlatform.initializeEnvironment(userDataFolder: file.path),
        throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'webview2Error')),
      );
    } finally {
      await channel.invokeMethod<void>('initialize');
    }
  });

  testWidgets('JavaScript declarations persist in the page context', (WidgetTester tester) async {
    final controller = WebViewController();
    addTearDown((controller.platform as WindowsWebViewController).dispose);
    await _loadHtml(controller, '<!doctype html><html><body></body></html>');
    await controller.runJavaScript('const counter = {value: 41};');
    expect(await controller.runJavaScriptReturningResult('counter.value + 1'), 42);
  });

  testWidgets('hidden windows retain a viewport and page state', (WidgetTester tester) async {
    final controller = WebViewController();
    addTearDown((controller.platform as WindowsWebViewController).dispose);
    await _loadHtml(controller, '<p>Hidden capture</p>');
    Widget frame(bool shown) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 640,
          height: 480,
          child: Offstage(
            offstage: !shown,
            child: WebViewWidget(controller: controller),
          ),
        ),
      ),
    );
    await tester.pumpWidget(frame(false));
    await tester.pump();
    final width = await controller.runJavaScriptReturningResult('innerWidth');
    expect(width, greaterThan(0));
    expect(await controller.runJavaScriptReturningResult('innerHeight'), greaterThan(0));
    expect(await controller.runJavaScriptReturningResult('document.visibilityState'), 'hidden');
    await controller.runJavaScript('window.captureCounter = 41');
    await tester.pumpWidget(frame(true));
    await tester.pump();
    expect(await controller.runJavaScriptReturningResult('document.visibilityState'), 'visible');
    await tester.pumpWidget(frame(false));
    await tester.pump();
    expect(await controller.runJavaScriptReturningResult('innerWidth'), width);
    expect(await controller.runJavaScriptReturningResult('++window.captureCounter'), 42);
    expect(await controller.runJavaScriptReturningResult('document.visibilityState'), 'hidden');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('JavaScript channels deliver messages from child frames', (
    WidgetTester tester,
  ) async {
    final controller = WebViewController();
    addTearDown((controller.platform as WindowsWebViewController).dispose);
    final message = Completer<String>();
    await controller.addJavaScriptChannel(
      'Messages',
      onMessageReceived: (JavaScriptMessage event) {
        if (!message.isCompleted) {
          message.complete(event.message);
        }
      },
    );
    await _loadHtml(controller, '''
<!doctype html><html><body>
<iframe srcdoc="<script>Messages.postMessage('frame');</script>"></iframe>
</body></html>
''');
    expect(await message.future.timeout(const Duration(seconds: 10)), 'frame');
  });

  testWidgets('initialization releases native views left by a hot restart', (
    WidgetTester tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/webview_flutter_windows');
    final int id = (await channel.invokeMethod<int>('create'))!;
    await channel.invokeMethod<void>('initialize');
    await expectLater(
      channel.invokeMethod<void>('reload', <String, int>{'id': id}),
      throwsA(
        isA<PlatformException>().having(
          (PlatformException error) => error.code,
          'code',
          'unknownWebView',
        ),
      ),
    );
  });

  testWidgets('WebView2 renders, navigates, evaluates scripts and shares cookies', (
    WidgetTester tester,
  ) async {
    expect(WebViewPlatform.instance, isA<WindowsWebViewPlatform>());
    final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = 'http://127.0.0.1:${server.port}';
    final requests = <String, String>{};
    final headers = <String, String?>{};
    final StreamSubscription<HttpRequest> subscription = server.listen((HttpRequest request) async {
      requests[request.uri.path] = await utf8.decoder.bind(request).join();
      headers[request.uri.path] = request.headers.value('x-test');
      if (request.uri.path == '/redirect') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set('location', '$origin/second');
      } else {
        request.response.headers.contentType = ContentType.html;
        request.response.write('''
<!doctype html><html><head><title>${request.uri.path}</title></head>
<body><h1>${request.uri.path}</h1><input id="input">
<script>document.body.dataset.scriptEnabled = 'yes';</script></body></html>
''');
      }

      await request.response.close();
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
    });

    final controller = WebViewController();
    final windows = controller.platform as WindowsWebViewController;
    addTearDown(windows.dispose);
    var finished = Completer<String>();
    final errors = <WebResourceError>[];
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (String url) {
          if (!finished.isCompleted) {
            finished.complete(url);
          }
        },
        onWebResourceError: errors.add,
      ),
    );
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WebViewWidget(controller: controller)),
      ),
    );
    await controller.loadRequest(Uri.parse('$origin/first'));
    expect(await finished.future.timeout(const Duration(seconds: 30)), '$origin/first');
    expect(await controller.getTitle(), '/first');
    expect(await controller.runJavaScriptReturningResult('6 * 7'), 42);
    await expectLater(
      controller.runJavaScript('throw new Error("intentional")'),
      throwsA(isA<PlatformException>()),
    );
    final message = Completer<String>();
    await controller.addJavaScriptChannel(
      'Messages',
      onMessageReceived: (JavaScriptMessage event) {
        if (!message.isCompleted) {
          message.complete(event.message);
        }
      },
    );
    await controller.runJavaScript('Messages.postMessage("hello")');
    expect(await message.future.timeout(const Duration(seconds: 10)), 'hello');
    await controller.removeJavaScriptChannel('Messages');
    expect(await controller.runJavaScriptReturningResult('typeof Messages'), 'undefined');

    finished = Completer<String>();
    await controller.loadRequest(
      Uri.parse('$origin/post'),
      method: LoadRequestMethod.post,
      headers: const <String, String>{'X-Test': 'preserved'},
      body: Uint8List.fromList(utf8.encode('a=hello&b=world')),
    );
    await finished.future.timeout(const Duration(seconds: 30));
    expect(requests['/post'], 'a=hello&b=world');
    expect(headers['/post'], 'preserved');
    finished = Completer<String>();
    await controller.loadRequest(Uri.parse('$origin/redirect'));
    expect(await finished.future.timeout(const Duration(seconds: 30)), '$origin/second');
    expect(await controller.currentUrl(), '$origin/second');
    expect(await controller.canGoBack(), isTrue);

    final cookies = WindowsWebViewCookieManager(const PlatformWebViewCookieManagerCreationParams());
    await cookies.setCookie(
      const WebViewCookie(name: 'test_cookie', value: 'value', domain: '127.0.0.1'),
    );
    expect(
      (await cookies.getCookies(Uri.parse(origin))).map((WebViewCookie c) => c.name),
      contains('test_cookie'),
    );
    expect(await cookies.clearCookies(), isTrue);
    expect(await cookies.clearCookies(), isFalse);
    await controller.runJavaScript('localStorage.setItem("test", "value")');
    await controller.clearCache();
    expect(await controller.runJavaScriptReturningResult('localStorage.getItem("test")'), 'value');
    await controller.clearLocalStorage();
    expect(
      await controller.runJavaScriptReturningResult('localStorage.getItem("test") === null'),
      isTrue,
    );
    expect(errors, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await windows.dispose();
    await expectLater(controller.reload(), throwsStateError);
  });
}

Future<void> _loadHtml(WebViewController controller, String html) async {
  final finished = Completer<void>();
  await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
  await controller.setNavigationDelegate(
    NavigationDelegate(
      onPageFinished: (String url) {
        if (!finished.isCompleted) {
          finished.complete();
        }
      },
    ),
  );
  await controller.loadHtmlString(html);
  await finished.future.timeout(const Duration(seconds: 30));
}
