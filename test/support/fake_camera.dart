import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const testCamera = CameraDescription(
  name: 'test-back-camera',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);

class FakeCameraController extends CameraController {
  FakeCameraController([CameraDescription description = testCamera])
    : super(description, ResolutionPreset.high);

  Completer<void>? initialization;
  Completer<XFile>? picture;
  Object? pictureError;
  Object? initializationError;
  Future<XFile> Function()? onPicture;
  Future<void> Function(double)? onZoom;
  Future<void> Function(FlashMode)? onFlash;
  Future<void> Function(Offset?)? onFocus;
  Future<void> Function()? onStartVideo;
  Future<XFile> Function()? onStopVideo;
  double zoomMin = 1, zoomMax = 8;
  final zoomCalls = <double>[];
  final flashCalls = <FlashMode>[];
  final focusCalls = <Offset?>[];
  final focusModeCalls = <FocusMode>[];
  bool focusPointSupported = true;
  int videoStarts = 0, videoStops = 0;
  int captures = 0;
  bool released = false;
  final releaseDone = Completer<void>();

  @override
  Future<void> initialize() async {
    await initialization?.future;
    if (initializationError != null) throw initializationError!;
    value = value.copyWith(
      isInitialized: true,
      previewSize: const Size(120, 100),
      focusPointSupported: focusPointSupported,
    );
  }

  @override
  Future<void> lockCaptureOrientation([DeviceOrientation? orientation]) async {}

  @override
  Future<void> setFlashMode(FlashMode mode) async {
    flashCalls.add(mode);
    await onFlash?.call(mode);
    value = value.copyWith(flashMode: mode);
  }

  @override
  Future<void> setFocusMode(FocusMode mode) async {
    focusModeCalls.add(mode);
    value = value.copyWith(focusMode: mode);
  }

  @override
  Future<void> setFocusPoint(Offset? point) async {
    focusCalls.add(point);
    await onFocus?.call(point);
  }

  @override
  Future<double> getMinZoomLevel() async => zoomMin;
  @override
  Future<double> getMaxZoomLevel() async => zoomMax;
  @override
  Future<void> setZoomLevel(double zoom) async {
    zoomCalls.add(zoom);
    await onZoom?.call(zoom);
  }

  @override
  Future<void> startVideoRecording({
    void Function(CameraImage)? onAvailable,
    bool enablePersistentRecording = true,
  }) async {
    videoStarts++;
    await onStartVideo?.call();
    value = value.copyWith(isRecordingVideo: true);
  }

  @override
  Future<XFile> stopVideoRecording() async {
    videoStops++;
    final file = await onStopVideo!.call();
    value = value.copyWith(isRecordingVideo: false);
    return file;
  }

  @override
  Future<XFile> takePicture() async {
    captures++;
    if (pictureError != null) throw pictureError!;
    if (onPicture != null) return onPicture!();
    return picture!.future;
  }

  @override
  Widget buildPreview() => const ColoredBox(color: Color(0xff6c7d85));

  @override
  Future<void> dispose() async {
    released = true;
    if (!releaseDone.isCompleted) releaseDone.complete();
    super.dispose();
  }
}
