import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'windows_webview_controller.dart';

/// Positions a native WebView2 child window over a rectangular Flutter widget.
///
/// Flutter clipping, transforms and widgets painted above this widget do not
/// affect the native window. See the package README for composition limitations.
class WindowsWebViewWidget extends PlatformWebViewWidget {
  /// Creates a Windows web view widget.
  WindowsWebViewWidget(super.params) : super.implementation() {
    if (params.controller is! WindowsWebViewController) {
      throw ArgumentError('The controller must be a WindowsWebViewController.');
    }
    if (params.gestureRecognizers.isNotEmpty) {
      throw UnsupportedError(
        'Native Windows web views do not participate in Flutter gesture arenas.',
      );
    }
  }

  @override
  Widget build(BuildContext context) =>
      _WindowsWebView(key: params.key, controller: params.controller as WindowsWebViewController);
}

class _WindowsWebView extends StatefulWidget {
  const _WindowsWebView({super.key, required this.controller});

  final WindowsWebViewController controller;

  @override
  State<_WindowsWebView> createState() => _WindowsWebViewState();
}

class _WindowsWebViewState extends State<_WindowsWebView> {
  static final Expando<bool> _attachedControllers = Expando<bool>();
  Rect? _bounds;
  bool? _nativeVisible;
  bool _visible = true;
  final FocusNode _focusNode = FocusNode();
  bool _nativeFocused = false;

  @override
  void initState() {
    super.initState();
    _attachController();
  }

  void _attachController() {
    if (_attachedControllers[widget.controller] ?? false) {
      throw FlutterError('A WindowsWebViewController can only be attached to one widget.');
    }
    _attachedControllers[widget.controller] = true;
    widget.controller.setFocusCallbacks(
      onFocus: () {
        _nativeFocused = true;
        _focusNode.requestFocus();
      },
      onMoveFocus: (bool reverse) {
        if (reverse) {
          _focusNode.previousFocus();
        } else {
          _focusNode.nextFocus();
        }
      },
    );
  }

  void _onFocusChange(bool focused) {
    if (focused && _nativeFocused) {
      return;
    }
    _nativeFocused = focused;
    unawaited(
      widget.controller
          .setFocus(focused, reverse: HardwareKeyboard.instance.isShiftPressed)
          .catchError((Object error, StackTrace stack) {
            if (mounted) {
              FlutterError.reportError(
                FlutterErrorDetails(
                  exception: error,
                  stack: stack,
                  library: 'webview_flutter_windows',
                  context: ErrorDescription('while transferring keyboard focus to WebView2'),
                ),
              );
            }
          }),
    );
  }

  void _disposeController(WindowsWebViewController controller) {
    _attachedControllers[controller] = false;
    controller.setFocusCallbacks();
    unawaited(
      controller.dispose().catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'webview_flutter_windows',
            context: ErrorDescription('while disposing a WebView2 window'),
          ),
        );
      }),
    );
  }

  @override
  void didUpdateWidget(_WindowsWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _disposeController(oldWidget.controller);
      _attachController();
      _bounds = null;
      _nativeVisible = null;
      _nativeFocused = false;
    }
  }

  void _updateBounds(RenderBox box) {
    if (!mounted || !box.attached || !box.hasSize) {
      return;
    }
    bool visible = _visible;
    RenderObject? ancestor = box.parent;
    while (ancestor != null) {
      if (ancestor is RenderOffstage && ancestor.offstage) {
        visible = false;
      }
      ancestor = ancestor.parent;
    }
    final double scale = View.of(context).devicePixelRatio;
    final Offset origin = box.localToGlobal(Offset.zero) * scale;
    final Rect bounds = origin & (box.size * scale);
    if (_bounds == bounds && _nativeVisible == visible) {
      return;
    }
    _bounds = bounds;
    _nativeVisible = visible;
    unawaited(
      widget.controller.setBounds(bounds, visible: visible).catchError((
        Object error,
        StackTrace stack,
      ) {
        if (mounted) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stack,
              library: 'webview_flutter_windows',
              context: ErrorDescription('while positioning a WebView2 window'),
            ),
          );
        }
      }),
    );
  }

  @override
  void dispose() {
    _disposeController(widget.controller);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _visible = TickerMode.valuesOf(context).enabled && (ModalRoute.isCurrentOf(context) ?? true);
    return Focus(
      focusNode: _focusNode,
      onFocusChange: _onFocusChange,
      child: _BoundsObserver(onBounds: _updateBounds),
    );
  }
}

class _BoundsObserver extends LeafRenderObjectWidget {
  const _BoundsObserver({required this.onBounds});

  final void Function(RenderBox) onBounds;

  @override
  _BoundsRenderBox createRenderObject(BuildContext context) => _BoundsRenderBox(onBounds);

  @override
  void updateRenderObject(BuildContext context, _BoundsRenderBox renderObject) {
    renderObject.onBounds = onBounds;
  }
}

class _BoundsRenderBox extends RenderBox {
  _BoundsRenderBox(this.onBounds);

  void Function(RenderBox) onBounds;
  bool _scheduled = false;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _observeFrame();
  }

  @override
  void performLayout() {
    if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
      throw FlutterError('A Windows WebViewWidget requires bounded width and height.');
    }
    size = constraints.biggest;
  }

  void _observeFrame() {
    if (!_scheduled) {
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) {
        _scheduled = false;
        if (attached) {
          onBounds(this);
          // Observe frames without requesting new ones, including frames where
          // an Offstage ancestor prevents this render object from painting.
          _observeFrame();
        }
      });
    }
  }
}
