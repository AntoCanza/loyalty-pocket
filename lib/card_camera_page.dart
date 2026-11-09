import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';

class CardCameraPage extends StatefulWidget {
  const CardCameraPage({super.key});

  @override
  State<CardCameraPage> createState() => _CardCameraPageState();
}

enum _CameraFailure { permission, unavailable }

class _CardCameraPageState extends State<CardCameraPage>
    with WidgetsBindingObserver {
  CameraController? _controller;
  Future<void> _cameraWork = Future<void>.value();
  _CameraFailure? _failure;
  bool _active = false;
  bool _backgrounded = false;
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    _active =
        binding.lifecycleState == null ||
        binding.lifecycleState == AppLifecycleState.resumed;
    _queue(_open);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (_active) {
      if (_backgrounded && _failure != null) setState(() => _failure = null);
      _backgrounded = false;
      _queue(_open);
    } else {
      _backgrounded |=
          state == AppLifecycleState.hidden ||
          state == AppLifecycleState.paused;
      if (_controller != null) _queue(_release);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _active = false;
    final controller = _controller;
    _controller = null;
    unawaited(_disposeController(controller));
    super.dispose();
  }

  // Wait for any permission prompt or capture before releasing the camera.
  void _queue(Future<void> Function() operation) {
    _cameraWork = _cameraWork.then((_) => operation());
  }

  Future<void> _open() async {
    if (!mounted || !_active || _controller != null || _failure != null) return;
    CameraController? opening;
    try {
      final cameras = await availableCameras();
      if (!mounted || !_active) return;
      if (cameras.isEmpty) {
        setState(() => _failure = _CameraFailure.unavailable);
        return;
      }
      final rear = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      opening = CameraController(
        rear,
        ResolutionPreset.veryHigh,
        enableAudio: false,
      );
      await opening.initialize();
      if (!mounted || !_active) return;
      setState(() => _controller = opening);
      opening = null;
    } on CameraException catch (error) {
      if (!mounted) return;
      setState(() {
        _failure = switch (error.code) {
          'CameraAccessDenied' ||
          'CameraAccessDeniedWithoutPrompt' ||
          'CameraAccessRestricted' => _CameraFailure.permission,
          _ => _CameraFailure.unavailable,
        };
      });
    } catch (_) {
      if (mounted) setState(() => _failure = _CameraFailure.unavailable);
    } finally {
      await _disposeController(opening);
    }
  }

  Future<void> _release() async {
    final controller = _controller;
    if (controller == null) return;
    _controller = null;
    if (mounted) setState(() {});
    await _disposeController(controller);
  }

  Future<void> _disposeController(CameraController? controller) async {
    try {
      await controller?.dispose();
    } catch (_) {
      // The platform may already have closed the camera.
    }
  }

  bool get _canCapture =>
      mounted && _active && ModalRoute.of(context)?.isCurrent == true;

  Future<XFile> _capture(CameraController controller) async {
    final pending = controller.takePicture();
    try {
      return await pending.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      unawaited(pending.then<void>(_discardPhoto, onError: (Object _) {}));
      await _release();
      if (_canCapture) await _open();
      rethrow;
    }
  }

  Future<void> _discardPhoto(XFile photo) async {
    try {
      await File(photo.path).delete();
    } on FileSystemException {
      // The system can clear its temporary camera files.
    }
  }

  void _takePhoto() {
    final controller = _controller;
    if (controller == null || _capturing || !_canCapture) return;
    setState(() => _capturing = true);
    _queue(() async {
      try {
        if (!_canCapture || !identical(controller, _controller)) return;
        final photo = await _capture(controller);
        if (_canCapture) {
          await _release();
          if (mounted && _canCapture) {
            Navigator.of(context).pop(photo);
            return;
          }
        }
        await _discardPhoto(photo);
      } catch (_) {
        if (!mounted || !_canCapture) return;
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.cardCaptureFailed)));
      } finally {
        if (mounted) setState(() => _capturing = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final controller = _controller;
    final error = switch (_failure) {
      _CameraFailure.permission => l10n.scanCameraPermissionDenied,
      _CameraFailure.unavailable => l10n.scanCameraUnavailable,
      null => null,
    };
    return Scaffold(
      appBar: AppBar(title: Text(l10n.cardTakePhoto)),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(l10n.scanCenterBarcode, textAlign: TextAlign.center),
            ),
            Expanded(
              child: switch (controller) {
                final camera? => ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: CameraPreview(camera, child: const _BarcodeFrame()),
                  ),
                ),
                null when error != null => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(error, textAlign: TextAlign.center),
                  ),
                ),
                null => const Center(child: CircularProgressIndicator()),
              },
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                onPressed: controller == null || _capturing ? null : _takePhoto,
                icon: const Icon(Icons.camera_alt_outlined),
                label: Text(l10n.cardTakePhoto),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BarcodeFrame extends StatelessWidget {
  const _BarcodeFrame();

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Center(
      child: FractionallySizedBox(
        widthFactor: .84,
        heightFactor: .45,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.black, width: 4),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
