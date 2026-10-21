import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  runApp(const MaterialApp(home: WebViewExample()));
}

/// A full-page native Windows web view, without overlapping Flutter widgets.
class WebViewExample extends StatefulWidget {
  /// Creates the example.
  const WebViewExample({super.key});

  @override
  State<WebViewExample> createState() => _WebViewExampleState();
}

class _WebViewExampleState extends State<WebViewExample> {
  final WebViewController _controller = WebViewController();
  late final Future<void> _initialization = _initialize();

  Future<void> _initialize() async {
    await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _controller.loadHtmlString('''
<!doctype html><html><head><title>WebView2 on Windows</title></head>
<body><h1>webview_flutter on Windows</h1>
<p>This page is rendered by Microsoft Edge WebView2.</p>
<input placeholder="Try keyboard input">
<button onclick="document.getElementById('result').textContent = 'JavaScript works'">Run JavaScript</button>
<p id="result"></p><a href="https://flutter.dev">Visit flutter.dev</a>
</body></html>
''');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Windows WebView2')),
      body: FutureBuilder<void>(
        future: _initialization,
        builder: (BuildContext context, AsyncSnapshot<void> snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Unable to create WebView2: ${snapshot.error}'));
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          return WebViewWidget(controller: _controller);
        },
      ),
    );
  }
}
