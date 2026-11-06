import 'dart:math' as math;

import 'package:flutter/material.dart';

class CameraLevelIndicator extends StatelessWidget {
  const CameraLevelIndicator({
    super.key,
    required this.angleDegrees,
    required this.isAvailable,
  });
  final double? angleDegrees;
  final bool isAvailable;

  @override
  Widget build(BuildContext context) {
    final angle = angleDegrees;
    final valid = isAvailable && angle != null && angle.isFinite;
    final aligned = valid && angle.abs() <= 2;
    return Semantics(
      label: !valid
          ? '수평계 측정 불가. 기기를 세워 주세요.'
          : aligned
          ? '수평입니다'
          : '기울기 ${angle.toStringAsFixed(1)}도',
      child: SizedBox(
        key: const Key('level-indicator'),
        width: 170,
        height: 70,
        child: Column(
          children: [
            SizedBox(
              width: 150,
              height: 38,
              child: CustomPaint(
                painter: _LevelPainter(valid ? angle : null, aligned),
              ),
            ),
            Text(
              !valid
                  ? '기기를 세워 주세요'
                  : aligned
                  ? '수평'
                  : '${angle.round()}°',
              key: const Key('level-angle'),
              style: TextStyle(
                color: aligned ? Colors.yellow : Colors.white,
                fontSize: 11,
                shadows: const [Shadow(blurRadius: 5, color: Colors.black)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LevelPainter extends CustomPainter {
  const _LevelPainter(this.angle, this.aligned);
  final double? angle;
  final bool aligned;

  @override
  void paint(Canvas canvas, Size size) {
    final middle = Offset(size.width / 2, size.height / 2);
    final reference = Paint()
      ..color = Colors.white70
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(0, middle.dy), Offset(25, middle.dy), reference);
    canvas.drawLine(
      Offset(size.width - 25, middle.dy),
      Offset(size.width, middle.dy),
      reference,
    );
    canvas.drawCircle(middle, 2, reference);
    if (angle == null) return;
    canvas.save();
    canvas.translate(middle.dx, middle.dy);
    canvas.rotate(-angle! * math.pi / 180);
    final line = Paint()
      ..color = aligned ? Colors.yellow : Colors.white
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(-40, 0), const Offset(40, 0), line);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LevelPainter oldDelegate) =>
      oldDelegate.angle != angle || oldDelegate.aligned != aligned;
}
