## 0.1.0

* Initial standalone release, independent of the Flutter packages repository.
* Generates the example's Windows runner locally instead of bundling SDK scaffolding.
* Adds an experimental Windows implementation using Microsoft Edge WebView2.
* Supports navigation, JavaScript, cookies, cache and storage operations.
* Documents native-window composition and unsupported API limitations.
* Adds optional shared profile-folder initialization with runtime-version reporting.
* Rejects invalid or conflicting profile selections instead of switching storage.
* Preserves laid-out viewport dimensions when a native window is hidden.
* Enables STL exception support so native argument errors retain valid messages.
