import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/film_filter.dart';

class CameraViewfinder extends StatelessWidget {
  const CameraViewfinder({
    super.key,
    required this.controller,
    required this.filter,
    required this.intensity,
    required this.isInitializing,
    required this.errorMessage,
    required this.onRetry,
  });

  final CameraController? controller;
  final FilmFilter filter;
  final double intensity;
  final bool isInitializing;
  final String? errorMessage;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final camera = controller;
    final ready = camera != null && camera.value.isInitialized;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (ready)
            _CoveredPreview(controller: camera)
          else
            _CameraPlaceholder(
              loading: isInitializing,
              errorMessage: errorMessage,
              onRetry: onRetry,
            ),
          if (ready && filter.assetPath != null)
            IgnorePointer(
              child: Opacity(
                opacity: intensity.clamp(0, 1),
                child: Image.asset(
                  filter.assetPath!,
                  fit: BoxFit.cover,
                  excludeFromSemantics: true,
                ),
              ),
            ),
          const IgnorePointer(
            child: CustomPaint(painter: _CameraGridPainter()),
          ),
        ],
      ),
    );
  }
}

class _CoveredPreview extends StatelessWidget {
  const _CoveredPreview({required this.controller});
  final CameraController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<CameraValue>(
    valueListenable: controller,
    builder: (context, value, _) {
      final size = value.previewSize;
      if (!value.isInitialized || size == null || size.isEmpty) {
        return const SizedBox.shrink();
      }
      final orientation =
          value.previewPauseOrientation ??
          value.lockedCaptureOrientation ??
          value.deviceOrientation;
      final portrait =
          orientation == DeviceOrientation.portraitUp ||
          orientation == DeviceOrientation.portraitDown;
      return ClipRect(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: portrait ? size.height : size.width,
            height: portrait ? size.width : size.height,
            child: CameraPreview(controller),
          ),
        ),
      );
    },
  );
}

class _CameraGridPainter extends CustomPainter {
  const _CameraGridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: .28)
      ..strokeWidth = .5;
    for (var part = 1; part < 3; part++) {
      final x = size.width * part / 3;
      final y = size.height * part / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_CameraGridPainter oldDelegate) => false;
}

class _CameraPlaceholder extends StatelessWidget {
  const _CameraPlaceholder({
    required this.loading,
    required this.errorMessage,
    required this.onRetry,
  });
  final bool loading;
  final String? errorMessage;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Align(
    alignment: const Alignment(0, -.35),
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            const CircularProgressIndicator(color: Colors.white)
          else
            const Icon(
              Icons.photo_camera_outlined,
              color: Colors.white70,
              size: 36,
            ),
          const SizedBox(height: 16),
          Text(
            loading ? '카메라를 준비하고 있어요' : (errorMessage ?? '카메라를 준비해 주세요'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, height: 1.6),
          ),
          if (!loading && onRetry != null) ...[
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
              child: const Text('카메라 다시 연결'),
            ),
          ],
        ],
      ),
    ),
  );
}
