import 'dart:async';

import 'package:aeroll/models/film_filter.dart';
import 'package:aeroll/models/zoom_keyframe.dart';
import 'package:aeroll/services/video_processor.dart';

class FakeVideoProcessor extends VideoProcessor {
  FilmFilter? selectedFilter;
  double? selectedIntensity;
  List<ZoomKeyframe> frames = [];
  Completer<void>? gate;
  Object? error;
  int exports = 0, successfulSaves = 0;
  @override
  String? get recoverableInputPath => error == null ? null : 'recoverable.mp4';
  @override
  Future<String> process({
    required String inputPath,
    required FilmFilter filter,
    required double intensity,
    required List<ZoomKeyframe> zoomKeyframes,
  }) async {
    exports++;
    selectedFilter = filter;
    selectedIntensity = intensity;
    frames = List.of(zoomKeyframes);
    await gate?.future;
    if (error != null) throw error!;
    return inputPath;
  }

  @override
  Future<void> completeSuccessfulSave() async {
    successfulSaves++;
  }
}
