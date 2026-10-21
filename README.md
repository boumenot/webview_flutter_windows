# webview_flutter_windows

An **experimental, opt-in Windows implementation** of
[`webview_flutter`](https://pub.dev/packages/webview_flutter), using Microsoft
Edge WebView2. This is a standalone package, independent of the Flutter packages
repository, and is not an endorsed implementation.

## Requirements

* Windows 10 or later.
* Flutter 3.41 / Dart 3.11 or later.
* The [Microsoft Edge WebView2 Evergreen Runtime](https://developer.microsoft.com/microsoft-edge/webview2/),
  version 131 or later.
  Applications must arrange runtime installation; the plugin does not install it.
* The Flutter Windows C++ build tools and `nuget.exe` on `PATH`. CMake restores
  the pinned Microsoft.Web.WebView2 SDK from NuGet when first building.

The native loader is statically linked; no separate WebView2Loader DLL is needed.
Its license and third-party notices are copied into the application bundle.
The example and integration tests have been exercised on Windows x64. The build
selects the ARM64 loader for Windows ARM64, but ARM64 has not been verified.

## Usage

Add both `webview_flutter` and `webview_flutter_windows` to your dependencies.
Windows registration is automatic; no explicit `registerWith` call is needed.
Reference this checkout with a `path` dependency; a package with the same name
already exists on pub.dev and is not this implementation:

```yaml
dependencies:
  webview_flutter: ^4.14.1
  webview_flutter_windows:
    path: 'C:\dev\webview_flutter_windows'
```

Use the normal `WebViewController`, `WebViewWidget`, `NavigationDelegate`, and
`WebViewCookieManager` APIs, subject to the limitations below. Await initialization
operations so a missing or outdated runtime is reported to your application.

See [the example](example/lib/main.dart) for a runnable Windows application
using the app-facing `webview_flutter` API.

## Hidden web views

Create and use a `WebViewController` without mounting a `WebViewWidget` to load
pages and execute JavaScript while the native web view remains hidden. Wait for
`NavigationDelegate.onPageFinished` before evaluating page-dependent scripts;
completion of `loadRequest` alone does not mean the page is ready.

When a controller is never attached to a widget, dispose it explicitly. Import
`package:webview_flutter_windows/webview_flutter_windows.dart` to access
`WindowsWebViewController`:

```dart
await (controller.platform as WindowsWebViewController).dispose();
```

Use `Offstage` to temporarily hide a mounted widget while retaining its
controller and laid-out viewport. Native visibility is independent of the
viewport dimensions. Removing the widget disposes the controller instead. Hidden web
views still require a running Flutter Windows application and its native
window; this is not a standalone headless browser service.

## Supported functionality

* URL loading, including GET/POST requests with custom headers and binary bodies.
* HTML strings (without `baseUrl`), local files, and Flutter HTML assets.
* Back/forward navigation, history availability, reload, current URL, and title.
* Page-started, page-finished, URL-change, HTTP-error, and main-frame load-error
  callbacks. Loading progress reports **0 and 100**, not intermediate progress.
* JavaScript execution/results and named JavaScript message channels.
* JavaScript enablement, zoom enablement, user agent, background color, and
  scrolling through JavaScript.
* Cookies shared by the application's web views, including access before a
  widget is created. Cache and local-storage clearing are separate operations.

JavaScript is disabled initially. `runJavaScriptReturningResult` returns
JSON-compatible values and rejects null/undefined results. JavaScript exceptions
are reported as `PlatformException`s.

By default, profiles are stored below `%LOCALAPPDATA%\flutter_webview`, isolated
by the application executable's full path. Web views in the same application
share cookies and storage; this is not an incognito implementation.

To select a different persistent folder, initialize the shared environment
**before using any controller or cookie manager**:

```dart
WidgetsFlutterBinding.ensureInitialized();
final runtimeVersion = await WindowsWebViewPlatform.initializeEnvironment(
  userDataFolder: r'C:\private\my-app-webview',
);
```

Import `package:webview_flutter_windows/webview_flutter_windows.dart` for this
Windows-only API. The folder must be absolute; WebView2 can create it if needed.
The returned string is the actual WebView2 runtime version. Existing callers
need no change: initialization remains lazy when this method is not used.
Omitting `userDataFolder` retains the default or already selected folder.
Repeating the same normalized selection is supported; changing it after
initialization starts fails with `environmentAlreadyInitialized`. Restart the
application to select another folder. An explicit selection is checked against
the actual environment, so an overriding WebView2 configuration cannot silently
redirect it elsewhere. Initialization and profile errors propagate to the caller.

This API does not copy, delete, reset, or export profile data. Use a dedicated
application folder, not a normal Edge account profile. Applications that require
existing storage or exclusive profile ownership must enforce those policies
before calling the initializer.

## Limitations

This implementation uses a **native child window**, not a Flutter texture or
composited platform view. Use it as an unobscured rectangular area:

* Flutter widgets cannot be painted above it. Overlapping menus, dialogs,
  tooltips, and other Flutter overlays are not supported.
* Flutter clipping, opacity, transforms, and gesture recognizers do not apply.
  Do not place it inside a scrolling or transformed Flutter layout.
* The widget tracks size, position, and display scaling. It hides for an
  `Offstage` ancestor, disabled `TickerMode`, or a non-current enclosing route.
* Only the implicit Flutter window (view ID 0) is supported.
* A controller can be attached to only one widget. Removing that widget disposes
  the controller; create a new controller when displaying another web view.
  If a controller is never attached, call
  `(controller.platform as WindowsWebViewController).dispose()` explicitly.

`NavigationDelegate.onNavigationRequest` is **not supported** and registering it
throws `UnsupportedError`. WebView2's `NavigationStarting` event does not provide
a deferral for asynchronous Dart decisions. Canceling and replaying requests
would change POST, redirect, and history behavior, so this plugin does not do so.
It must not be used where application-enforced navigation filtering is required.

Also not implemented: custom HTTP/SSL authentication handling, permission
callbacks, console/scroll callbacks, custom JavaScript dialogs, scrollbar
configuration, and overscroll configuration. These use the platform interface's
explicit unsupported-method errors. Permission requests are denied, pop-up
windows are suppressed, and ordinary JavaScript dialogs use WebView2's defaults.
Only fully transparent or fully opaque background colors are supported.
For relative URLs in HTML strings, include a `<base href="...">` element instead
of supplying `baseUrl`.

## Development

All tooling is local to this package; no Flutter monorepo checkout or scripts
are needed. From this directory:

```powershell
flutter pub get
dart format lib test example\lib example\integration_test
flutter analyze --fatal-infos
flutter test
Set-Location example
flutter create --platforms=windows --empty --project-name=webview_flutter_windows_example --no-pub .
flutter pub get
flutter test integration_test\webview_test.dart -d windows
flutter build windows --release
flutter run -d windows
```

Native integration tests require the WebView2 Runtime and a desktop session.
They use local HTML and a loopback HTTP server rather than external websites.
The example's Windows runner is generated from the installed Flutter SDK rather
than committed or published. Run the `flutter create` command above before the
first native test, build, or launch. It preserves the authored example files;
do not add `--overwrite`. The plugin's own native implementation in the
package-root `windows` directory remains part of the package.

The GitHub Actions workflow generates the example runner before running
formatting checks, analysis, unit/widget tests, a Windows example build, and a
publication dry run.

Format native code using `clang-format` and the included `.clang-format` file:

```powershell
clang-format -i windows\webview_flutter_windows_plugin.cpp windows\include\webview_flutter_windows\web_view_flutter_windows_plugin.h
```

## Publishing

The name `webview_flutter_windows` is already registered on pub.dev by another
project. Publishing under this name requires uploader access to that package;
otherwise, choose an available name and update the package, imports, and native
registration/build identifiers consistently before publishing.

Project metadata points to
[`boumenot/webview_flutter_windows`](https://github.com/boumenot/webview_flutter_windows).
Before publishing, make sure that repository is available, review
`CHANGELOG.md`, choose a version appropriate for the package's release history,
and inspect the archive from the package root:

```powershell
dart pub publish --dry-run
```

The archive includes the Dart implementation, plugin native Windows sources,
authored example files, tests, and license. It excludes the generated example
Windows runner, build outputs, restored SDKs, local dependency overrides, and
tool caches. Publishing is a separate, manual action.

## License

Copyright (c) 2026 Christopher Boumenot. Distributed under the BSD-3-Clause
terms in [LICENSE](LICENSE).

The WebView2 SDK has its own license and third-party notices, which the native
build preserves in the application bundle. Generating the example runner locally
does not change the licensing terms of Flutter or other dependencies.
