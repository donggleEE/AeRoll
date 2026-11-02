import 'dart:typed_data';

import 'package:aeroll/services/photo_processor.dart';

class FakePhotoProcessor extends PhotoProcessor {
  final calls =
      <({String? asset, double intensity, double ratio, bool mirror})>[];
  bool closed = false;
  @override
  Future<void> preload() async {}
  @override
  Future<Uint8List> process({
    required Uint8List photoBytes,
    String? overlayAsset,
    required double intensity,
    required double frameAspectRatio,
    required bool mirrorHorizontally,
  }) async {
    calls.add((
      asset: overlayAsset,
      intensity: intensity,
      ratio: frameAspectRatio,
      mirror: mirrorHorizontally,
    ));
    return photoBytes;
  }

  @override
  Future<void> dispose() async {
    closed = true;
    await super.dispose();
  }
}
