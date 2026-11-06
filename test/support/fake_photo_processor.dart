import 'dart:typed_data';

import 'package:aeroll/services/photo_processor.dart';
import 'package:aeroll/services/photo_capture_store.dart';

class MemoryPhotoCaptureStore extends PhotoCaptureStore {
  final data = <String, Uint8List>{};
  @override
  Future<void> stage(PhotoCaptureJob job, Uint8List bytes) async =>
      data[job.id] = bytes;
  @override
  Future<Uint8List> read(PhotoCaptureJob job) async => data[job.id]!;
  @override
  Future<List<PhotoCaptureJob>> pending() async => [];
  @override
  Future<void> complete(PhotoCaptureJob job) async {
    data.remove(job.id);
  }
}

class FakePhotoProcessor extends PhotoProcessor {
  final calls =
      <({String filterId, double intensity, double ratio, bool mirror})>[];
  bool closed = false;
  final digitalScales = <double>[];
  @override
  Future<void> preload() async {}
  @override
  Future<Uint8List> process({
    required Uint8List photoBytes,
    String filterId = 'original',
    bool lossless = false,
    required double intensity,
    required double frameAspectRatio,
    required bool mirrorHorizontally,
    double digitalScale = 1,
  }) async {
    digitalScales.add(digitalScale);
    calls.add((
      filterId: filterId,
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
