import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 로그 배율 눈금. 입력이 없을 때의 표시·숨김은 카메라 화면이 관리한다.
class ZoomRuler extends StatelessWidget {
  const ZoomRuler({
    super.key,
    required this.zoom,
    required this.minZoom,
    required this.maxZoom,
    required this.isDigital,
  });
  final double zoom;
  final double minZoom;
  final double maxZoom;
  final bool isDigital;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '${zoom.toStringAsFixed(1)}배 확대${isDigital ? ', 디지털 확대' : ''}',
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .25),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(5, 7, 5, 7),
        child: Column(
          children: [
            Text(
              '${zoom.toStringAsFixed(1)}×',
              key: const Key('zoom-value'),
              maxLines: 1,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 5),
            Expanded(
              child: CustomPaint(
                key: const Key('zoom-ruler-ticks'),
                painter: _RulerPainter(zoom, minZoom, maxZoom),
                child: const SizedBox.expand(),
              ),
            ),
            if (isDigital)
              const Padding(
                padding: EdgeInsets.only(top: 3),
                child: Text(
                  '디지털',
                  maxLines: 1,
                  style: TextStyle(color: Colors.white70, fontSize: 9),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _RulerPainter extends CustomPainter {
  const _RulerPainter(this.zoom, this.minZoom, this.maxZoom);
  final double zoom;
  final double minZoom;
  final double maxZoom;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || minZoom <= 0 || maxZoom <= minZoom) return;
    final lineX = size.width - 9;
    final line = Paint()
      ..color = Colors.white70
      ..strokeWidth = 1;
    final active = Paint()
      ..color = Colors.white
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    const top = 4.0;
    final bottom = math.max(top, size.height - 4);
    canvas.drawLine(Offset(lineX, top), Offset(lineX, bottom), line);
    for (var index = 0; index <= 20; index++) {
      final y = top + (bottom - top) * index / 20;
      canvas.drawLine(
        Offset(lineX - (index % 5 == 0 ? 16 : 8), y),
        Offset(lineX, y),
        line,
      );
    }
    final normalized =
        (math.log(zoom.clamp(minZoom, maxZoom) / minZoom) /
                math.log(maxZoom / minZoom))
            .clamp(0, 1);
    final y = bottom - (bottom - top) * normalized;
    canvas.drawLine(Offset(lineX - 22, y), Offset(lineX + 3, y), active);
  }

  @override
  bool shouldRepaint(_RulerPainter oldDelegate) =>
      oldDelegate.zoom != zoom ||
      oldDelegate.minZoom != minZoom ||
      oldDelegate.maxZoom != maxZoom;
}
