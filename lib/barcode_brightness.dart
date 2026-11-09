import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class BarcodeBrightness extends StatefulWidget {
  const BarcodeBrightness({super.key, required this.child});

  final Widget child;

  @override
  State<BarcodeBrightness> createState() => _BarcodeBrightnessState();
}

class _BarcodeBrightnessState extends State<BarcodeBrightness>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('loyalty_pocket/screen_brightness');

  ScrollPosition? _position;
  bool _routeIsCurrent = false;
  bool _updateScheduled = false;
  bool _bright = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (_position != position) {
      _position?.removeListener(_scheduleUpdate);
      _position = position;
      _position?.addListener(_scheduleUpdate);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleUpdate();
    } else {
      _requestBrightness(false);
    }
  }

  @override
  void didChangeMetrics() => _scheduleUpdate();

  @override
  void dispose() {
    _position?.removeListener(_scheduleUpdate);
    WidgetsBinding.instance.removeObserver(this);
    _requestBrightness(false);
    super.dispose();
  }

  void _scheduleUpdate() {
    if (_updateScheduled) return;
    _updateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateScheduled = false;
      if (!mounted) return;
      _requestBrightness(
        _routeIsCurrent &&
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed &&
            _isInViewport(),
      );
    });
  }

  bool _isInViewport() {
    final box = context.findRenderObject();
    if (box is! RenderBox ||
        !box.attached ||
        !box.hasSize ||
        box.size.isEmpty) {
      return false;
    }
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return true;
    final bounds = MatrixUtils.transformRect(
      box.getTransformTo(viewport),
      box.paintBounds,
    );
    return bounds.overlaps(viewport.paintBounds);
  }

  void _requestBrightness(bool bright) {
    if (_bright == bright) return;
    _bright = bright;
    unawaited(_setBrightness(bright));
  }

  Future<void> _setBrightness(bool bright) async {
    try {
      await _channel.invokeMethod<void>('setBarcodeVisible', bright);
    } on MissingPluginException {
      // The barcode remains usable without a native brightness override.
    } on PlatformException {
      // The barcode remains usable without a native brightness override.
    }
  }

  @override
  Widget build(BuildContext context) {
    _routeIsCurrent = ModalRoute.isCurrentOf(context) == true;
    _scheduleUpdate();
    return widget.child;
  }
}
