import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/film_filter.dart';
import '../models/saved_photo.dart';
import '../services/photo_processor.dart';
import '../services/photo_repository.dart';

/// 카메라 자원과 촬영-합성-저장의 상태를 화면과 분리한다.
class CameraSession extends ChangeNotifier {
  CameraSession({
    PhotoRepository? repository,
    Future<List<CameraDescription>> Function()? cameraLoader,
    CameraController Function(CameraDescription)? controllerFactory,
    bool? isSupported,
    PhotoProcessor? photoProcessor,
  }) : repository = repository ?? PhotoRepository(),
       _cameraLoader = cameraLoader ?? availableCameras,
       _controllerFactory = controllerFactory ?? _createController,
       _isSupported = isSupported ?? (Platform.isAndroid || Platform.isIOS),
       _photoProcessor = photoProcessor ?? PhotoProcessor();

  final PhotoRepository repository;
  final Future<List<CameraDescription>> Function() _cameraLoader;
  final CameraController Function(CameraDescription) _controllerFactory;
  final bool _isSupported;
  final PhotoProcessor _photoProcessor;
  List<CameraDescription> _cameras = [];
  CameraDescription? _selectedCamera;
  bool _isSwitchingCamera = false;
  bool get isSwitchingCamera => _isSwitchingCamera;
  bool get isFrontCamera =>
      (_controller?.description ?? _selectedCamera)?.lensDirection ==
      CameraLensDirection.front;
  bool get canSwitchCamera =>
      !_disposed &&
      !_suspended &&
      !_isCapturing &&
      !_isInitializing &&
      !_isSwitchingCamera &&
      _cameras.any((c) => c.lensDirection == CameraLensDirection.front) &&
      _cameras.any((c) => c.lensDirection == CameraLensDirection.back);
  static const maxPendingSaves = 3;
  int _pendingSaves = 0;
  int get pendingSaves => _pendingSaves;
  bool get canCapture =>
      !_disposed &&
      !_suspended &&
      !_isInitializing &&
      !_isSwitchingCamera &&
      !_isCapturing &&
      _pendingSaves < maxPendingSaves &&
      (_controller?.value.isInitialized ?? false);
  Duration? lastCaptureDuration;
  Duration? lastSaveDuration;
  Future<void> _saving = Future<void>.value();
  Completer<void>? _cameraCaptureDone;
  CameraController? _controller;
  CameraController? get cameraController => _controller;
  bool _isInitializing = false;
  bool get isInitializing => _isInitializing;
  bool _isCapturing = false;
  bool get isCapturing => _isCapturing;
  String? _errorMessage;
  String? get errorMessage => _errorMessage;
  bool _disposed = false;
  bool _suspended = false;
  int _generation = 0;
  Future<void> _lifecycle = Future<void>.value();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final operation = _lifecycle.then((_) => action());
    // 이후 작업이 이전 작업의 오류 때문에 실행되지 않는 상황을 막는다.
    _lifecycle = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> initialize() {
    if (_disposed) return Future<void>.value();
    _suspended = false;
    return _enqueue(_initializeCamera);
  }

  Future<void> _initializeCamera() async {
    if (_disposed || _suspended) return;
    if (_controller?.value.isInitialized ?? false) return;
    if (!_isSupported) {
      _errorMessage = '카메라 촬영은 Android 또는 iOS 기기에서 사용할 수 있습니다.';
      _notify();
      return;
    }
    final generation = _generation;
    _isInitializing = true;
    _errorMessage = null;
    _notify();
    CameraController? candidate;
    try {
      final cameras = await _cameraLoader();
      _cameras = cameras;
      if (cameras.isEmpty) {
        throw CameraException('NoCamera', '사용 가능한 카메라가 없습니다.');
      }
      final backCameras = cameras.where(
        (camera) => camera.lensDirection == CameraLensDirection.back,
      );
      final previous = cameras.where((c) => c.name == _selectedCamera?.name);
      final description = previous.isNotEmpty
          ? previous.first
          : backCameras.isNotEmpty
          ? backCameras.first
          : cameras.first;
      _selectedCamera = description;
      candidate = _controllerFactory(description);
      await candidate.initialize();
      await candidate.lockCaptureOrientation(DeviceOrientation.portraitUp);
      try {
        await candidate.setFlashMode(FlashMode.off);
      } catch (_) {
        // 플래시가 없는 카메라에서도 촬영은 허용한다.
      }
      if (_disposed || _suspended || generation != _generation) {
        await candidate.dispose();
        candidate = null;
        return;
      }
      _controller = candidate;
      candidate = null;
      unawaited(_photoProcessor.preload().catchError((Object _) {}));
    } on CameraException catch (error) {
      if (!_disposed && generation == _generation) {
        _errorMessage = _cameraError(error);
      }
    } catch (_) {
      if (!_disposed && generation == _generation) {
        _errorMessage = '카메라를 시작하지 못했습니다. 다시 시도해 주세요.';
      }
    } finally {
      if (candidate != null) {
        try {
          await candidate.dispose();
        } catch (_) {
          // 초기화 실패의 원인을 해제 오류로 바꾸지 않는다.
        }
      }
      _isInitializing = false;
      _notify();
    }
  }

  Future<SavedPhoto> capture({
    required FilmFilter filter,
    required double intensity,
    double frameAspectRatio = 5 / 6,
  }) async {
    if (_disposed || _suspended) {
      throw const PhotoStorageException(
        '카메라가 중지되어 있습니다. 화면으로 돌아온 뒤 다시 촬영해 주세요.',
      );
    }
    if (_isCapturing || _isInitializing || _isSwitchingCamera) {
      throw const PhotoStorageException('카메라를 준비 중입니다. 잠시 기다려 주세요.');
    }
    if (_pendingSaves >= maxPendingSaves) {
      throw const PhotoStorageException('사진 3장을 저장 중입니다. 잠시 후 다시 촬영해 주세요.');
    }
    if (!intensity.isFinite || intensity < 0 || intensity > 1) {
      throw const PhotoStorageException('필터 강도는 0~1이어야 합니다.');
    }
    if (!frameAspectRatio.isFinite || frameAspectRatio <= 0) {
      throw const PhotoStorageException('촬영 화면 비율이 올바르지 않습니다.');
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      throw const PhotoStorageException('카메라를 준비한 뒤 다시 촬영해 주세요.');
    }
    _isCapturing = true;
    final mirrorHorizontally = isFrontCamera;
    final captureTimer = Stopwatch()..start();
    final cameraCaptureDone = Completer<void>();
    _cameraCaptureDone = cameraCaptureDone;
    _errorMessage = null;
    _notify();
    XFile? original;
    Uint8List? bytes;
    try {
      // filter와 intensity는 이 요청의 인자로 고정된다.
      original = await controller.takePicture();
      bytes = await original.readAsBytes();
    } on CameraException catch (error) {
      _errorMessage = _cameraError(error);
      throw PhotoStorageException(_errorMessage!);
    } on PhotoStorageException catch (error) {
      _errorMessage = error.message;
      rethrow;
    } catch (_) {
      _errorMessage = '사진을 처리하지 못했습니다. 다시 촬영해 주세요.';
      throw PhotoStorageException(_errorMessage!);
    } finally {
      if (!cameraCaptureDone.isCompleted) cameraCaptureDone.complete();
      if (identical(_cameraCaptureDone, cameraCaptureDone)) {
        _cameraCaptureDone = null;
      }
      if (original != null) unawaited(_deleteTemporaryFile(original.path));
      captureTimer.stop();
      lastCaptureDuration = captureTimer.elapsed;
      if (bytes != null) _pendingSaves++;
      _isCapturing = false;
      _notify();
    }
    final result = Completer<SavedPhoto>();
    final capturedBytes = bytes;
    _saving = _saving.then((_) async {
      final saveTimer = Stopwatch()..start();
      try {
        final processed = await _photoProcessor.process(
          photoBytes: capturedBytes,
          overlayAsset: filter.assetPath,
          intensity: intensity,
          frameAspectRatio: frameAspectRatio,
          mirrorHorizontally: mirrorHorizontally,
        );
        final saved = await repository.savePhoto(
          bytes: processed,
          filterName: filter.name,
        );
        result.complete(saved);
      } catch (error) {
        final failure = error is PhotoStorageException
            ? error
            : const PhotoStorageException('사진을 처리하지 못했습니다. 다시 촬영해 주세요.');
        _errorMessage = failure.message;
        result.completeError(failure);
      } finally {
        saveTimer.stop();
        lastSaveDuration = saveTimer.elapsed;
        _pendingSaves--;
        _notify();
      }
    });
    return result.future;
  }

  static Future<void> _deleteTemporaryFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 카메라 임시 파일 정리가 저장 결과를 바꾸지 않는다.
    }
  }

  Future<void> switchCamera() {
    if (!canSwitchCamera) return Future<void>.value();
    _isSwitchingCamera = true;
    _notify();
    return _enqueue(() async {
      try {
        final direction = isFrontCamera
            ? CameraLensDirection.back
            : CameraLensDirection.front;
        final next = _cameras.firstWhere((c) => c.lensDirection == direction);
        final old = _controller;
        _controller = null;
        _selectedCamera = next;
        _notify();
        await _cameraCaptureDone?.future;
        await old?.dispose();
        await _initializeCamera();
      } finally {
        _isSwitchingCamera = false;
        _notify();
      }
    });
  }

  Future<void> suspend() {
    _suspended = true;
    _generation++;
    return _enqueue(() async {
      final controller = _controller;
      _controller = null;
      _notify();
      await _cameraCaptureDone?.future;
      await controller?.dispose();
    });
  }

  Future<void> resume() => initialize();

  static CameraController _createController(CameraDescription description) =>
      CameraController(
        description,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

  static String _cameraError(CameraException error) => switch (error.code) {
    'CameraAccessDenied' => '카메라 권한이 필요합니다. 설정에서 권한을 허용해 주세요.',
    'CameraAccessDeniedWithoutPrompt' =>
      '카메라 권한이 거부되었습니다. 기기 설정에서 권한을 허용해 주세요.',
    'CameraAccessRestricted' => '이 기기에서는 카메라 접근이 제한되어 있습니다.',
    'NoCamera' => '사용 가능한 카메라가 없습니다.',
    _ => '카메라를 사용할 수 없습니다. 다시 시도해 주세요.',
  };

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _suspended = true;
    _generation++;
    final controller = _controller;
    _controller = null;
    // ChangeNotifier.dispose는 동기 메서드이므로 비동기 해제를 큐에 둔다.
    _enqueue(() async {
      try {
        await _cameraCaptureDone?.future;
        await controller?.dispose();
      } catch (_) {
        // 종료 중에는 UI에 오류를 전달할 수 없다.
      }
    });
    unawaited(_closeProcessorAfterCaptures());
    super.dispose();
  }

  Future<void> _closeProcessorAfterCaptures() async {
    await _cameraCaptureDone?.future;
    // 바이트 취득을 마친 요청이 저장 큐에 들어가는 마이크로태스크까지 기다린다.
    await Future<void>.delayed(Duration.zero);
    await _saving;
    await _photoProcessor.dispose();
  }
}
