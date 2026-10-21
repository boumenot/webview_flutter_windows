# Windows WebView example

A runnable Flutter application using the app-facing `webview_flutter` API with
the standalone Windows plugin through a local `path: ..` dependency. No
monorepo checkout or published Windows implementation is required.

Install the WebView2 Evergreen Runtime and the Flutter Windows build tools.
Make `nuget.exe` available on `PATH`, then run from this example directory:

```powershell
flutter create --platforms=windows --empty --project-name=webview_flutter_windows_example --no-pub .
flutter pub get
flutter run -d windows
```

The Windows runner is standard Flutter SDK scaffolding, generated locally rather
than committed or included in the published package. The command preserves the
existing Dart example, dependency manifest, and integration tests. `--empty`
avoids generating an unrelated counter-app test; do not add `--overwrite`.
Run it after a fresh checkout or whenever the generated `windows` directory
has been removed. Generated files and `.metadata` are ignored by Git.

The example displays a local HTML page with keyboard input, JavaScript, and a
link to flutter.dev. It reports WebView2 initialization failures in the UI.

To exercise the native implementation using a local HTTP server:

```powershell
flutter test integration_test\webview_test.dart -d windows
```

See the package README for the limitations of native child-window composition.

To create a release build:

```powershell
flutter build windows --release
```
