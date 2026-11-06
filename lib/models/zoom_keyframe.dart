class ZoomKeyframe {
  const ZoomKeyframe({required this.timeMs, required this.digitalScale});
  final int timeMs;
  final double digitalScale;

  Map<String, Object> toJson() => {
    'timeMs': timeMs,
    'digitalScale': digitalScale,
  };
}
