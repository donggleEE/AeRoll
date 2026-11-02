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
  Future<XFile> Function()? onPicture;
  int captures = 0;
  bool released = false;

  @override
  Future<void> initialize() async {
    await initialization?.future;
    value = value.copyWith(
      isInitialized: true,
      previewSize: const Size(120, 100),
    );
  }

  @override
  Future<void> lockCaptureOrientation([DeviceOrientation? orientation]) async {}

  @override
  Future<void> setFlashMode(FlashMode mode) async {}

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
    super.dispose();
  }
}
