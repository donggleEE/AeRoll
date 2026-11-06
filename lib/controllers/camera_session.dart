import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/film_filter.dart';
import '../models/saved_photo.dart';
import '../models/zoom_keyframe.dart';
import '../services/photo_processor.dart';
import '../services/photo_capture_store.dart';
import '../services/photo_repository.dart';
import '../services/video_processor.dart';

/// 카메라 자원과 촬영-합성-저장의 상태를 화면과 분리한다.
class CameraSession extends ChangeNotifier {
  CameraSession({
    PhotoRepository? repository,
    Future<List<CameraDescription>> Function()? cameraLoader,
    this.controllerFactory,
    this.modeControllerFactory,
    Future<bool> Function(CameraDescription)? flashSupportLoader,
    bool? isSupported,
    PhotoProcessor? photoProcessor,
    PhotoCaptureStore? captureStore,
    VideoProcessor? videoProcessor,
  }) : repository = repository ?? PhotoRepository(),
       _cameraLoader = cameraLoader ?? availableCameras,
       _flashSupportLoader = flashSupportLoader ?? _loadFlashSupport,
       _isSupported = isSupported ?? (Platform.isAndroid || Platform.isIOS),
       _photoProcessor = photoProcessor ?? PhotoProcessor(),
       _captureStore = captureStore ?? PhotoCaptureStore(),
       _videoProcessor = videoProcessor ?? VideoProcessor();

  final PhotoRepository repository;
  final Future<List<CameraDescription>> Function() _cameraLoader;
  final Future<bool> Function(CameraDescription) _flashSupportLoader;
  final CameraController Function(CameraDescription)? controllerFactory;
  final CameraController Function(CameraDescription, bool)?
  modeControllerFactory;
  final bool _isSupported;
  final PhotoProcessor _photoProcessor;
  final PhotoCaptureStore _captureStore;
  final _failedPhotoJobs = <String, PhotoCaptureJob>{};
  final _unstagedSources = <String, String>{};
  bool _recoveryLoaded = false;
  int get recoverablePhotoCount => _failedPhotoJobs.length;
  Uint8List? latestPhotoThumbnail;
  String? latestPhotoThumbnailId;
  SavedPhoto? _lastSavedPhoto;
  SavedPhoto? get lastSavedPhoto => _lastSavedPhoto;
  final _photoTimings = <String, Map<String, int>>{};
  final _photoClocks = <String, Stopwatch>{};
  Stopwatch? _photoInputClock;
  void notePhotoInput() => _photoInputClock = Stopwatch()..start();
  Map<String, Map<String, int>> get photoTimings => Map.unmodifiable({
    for (final entry in _photoTimings.entries)
      entry.key: Map<String, int>.unmodifiable(entry.value),
  });

  void markThumbnailPresented(String id) {
    final stages = _photoTimings[id];
    final clock = _photoClocks[id];
    if (stages == null ||
        clock == null ||
        stages.containsKey('thumbnailPresented')) {
      return;
    }
    stages['thumbnailPresented'] = clock.elapsedMicroseconds;
    stages['savedToThumbnail'] =
        clock.elapsedMicroseconds - (stages['totalSaved'] ?? 0);
  }

  final VideoProcessor _videoProcessor;
  double _nativeMinZoom = 1;
  double _nativeMaxZoom = 1;
  double get nativeMaxZoom => _nativeMaxZoom;
  double _appliedNativeZoom = 1;
  double get previewDigitalZoom =>
      (_currentZoom / _appliedNativeZoom).clamp(1.0, 1000.0);
  bool get isDigitalZoom => previewDigitalZoom > 1.001;
  bool _isVideoProcessing = false;
  bool get isVideoProcessing => _isVideoProcessing;
  FilmFilter _recordingFilter = filmFilters.first;
  double _recordingIntensity = 1;
  final Stopwatch _recordingClock = Stopwatch();
  final List<ZoomKeyframe> _zoomKeyframes = [];
  double _minZoom = 1;
  double get minZoom => _minZoom;
  double _maxZoom = 1;
  double get maxZoom => _maxZoom;
  double _currentZoom = 1;
  double get currentZoom => _currentZoom;
  double? _requestedZoom;
  Future<void>? _zoomOperation;
  Future<void> _cameraControlOperation = Future<void>.value();
  int _pendingCameraControls = 0;
  bool _desiredFlashEnabled = false;
  bool _flashEnabled = false;
  bool get flashEnabled => _flashEnabled;
  bool _flashSupported = false;
  bool get flashSupported => _flashSupported;
  bool _isFlashBusy = false;
  bool get isFlashBusy => _isFlashBusy;
  bool get _canControlCamera =>
      !_disposed &&
      !_suspended &&
      !_isInitializing &&
      !_isSwitchingCamera &&
      !_isCapturing &&
      !_isRecordingBusy &&
      (_controller?.value.isInitialized ?? false);
  bool get canSetFocus =>
      _canControlCamera && (_controller?.value.focusPointSupported ?? false);
  bool get canToggleFlash =>
      _canControlCamera && !_videoMode && _flashSupported && !_isFlashBusy;
  bool _videoMode = false;
  bool get videoMode => _videoMode;
  bool _isRecording = false;
  bool get isRecording => _isRecording;
  bool _isRecordingBusy = false;
  bool get isRecordingBusy => _isRecordingBusy;
  bool get canStartRecording =>
      _videoMode &&
      !_isRecording &&
      !_isRecordingBusy &&
      !_disposed &&
      !_suspended &&
      !_isInitializing &&
      !_isSwitchingCamera &&
      !_isCapturing &&
      (_controller?.value.isInitialized ?? false);
  SavedPhoto? _lastSavedVideo;
  SavedPhoto? get lastSavedVideo => _lastSavedVideo;
  Future<SavedPhoto>? _stoppingRecording;
  String? _recoverableVideoPath;
  String? get recoverableVideoPath => _recoverableVideoPath;
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
      !_isRecording &&
      !_isRecordingBusy &&
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
      !_isFlashBusy &&
      !_videoMode &&
      !_isRecording &&
      !_isRecordingBusy &&
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
      candidate =
          modeControllerFactory?.call(description, _videoMode) ??
          controllerFactory?.call(description) ??
          _createController(description, _videoMode);
      await candidate.initialize();
      await candidate.lockCaptureOrientation(DeviceOrientation.portraitUp);
      _flashEnabled = false;
      _flashSupported = false;
      try {
        // 지원 여부는 발광 테스트 대신 플랫폼의 실제 카메라 특성으로 조회한다.
        _flashSupported = await _flashSupportLoader(description);
      } catch (_) {
        // 조회할 수 없는 환경에서는 지원한다고 추측하지 않는다.
      }
      try {
        await candidate.setFlashMode(FlashMode.off);
        if (_flashSupported && _desiredFlashEnabled && !_videoMode) {
          await candidate.setFlashMode(FlashMode.always);
          _flashEnabled = true;
        }
      } catch (_) {
        _flashSupported = false;
        _flashEnabled = false;
      }
      _minZoom = 1;
      _maxZoom = 100;
      _currentZoom = 1;
      _nativeMinZoom = _nativeMaxZoom = _appliedNativeZoom = 1;
      try {
        final min = await candidate.getMinZoomLevel();
        final max = await candidate.getMaxZoomLevel();
        if (min.isFinite && max.isFinite && min > 0 && max >= min) {
          _nativeMinZoom = min;
          _nativeMaxZoom = max;
          _minZoom = min.clamp(.6, 100.0);
          _currentZoom = 1.0.clamp(_minZoom, 100.0);
          _appliedNativeZoom = _currentZoom.clamp(min, max);
          await candidate.setZoomLevel(_appliedNativeZoom);
        }
      } catch (_) {
        // 줌 미지원 카메라도 기본 배율로 촬영할 수 있다.
        _minZoom = _currentZoom = _appliedNativeZoom = 1;
        _nativeMinZoom = _nativeMaxZoom = 1;
      }
      if (_disposed || _suspended || generation != _generation) {
        await candidate.dispose();
        candidate = null;
        return;
      }
      _controller = candidate;
      candidate = null;
      if (!_recoveryLoaded) {
        _recoveryLoaded = true;
        try {
          for (final job in await _captureStore.pending()) {
            _failedPhotoJobs[job.id] = job;
          }
        } catch (_) {
          // 복구 조회 실패는 새 촬영을 차단하지 않는다. 원본은 삭제하지 않는다.
        }
      }
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
    if (_videoMode || _isRecording || _isRecordingBusy) {
      throw const PhotoStorageException('사진 모드에서 촬영해 주세요.');
    }
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
    final captureTimer = _photoInputClock ?? (Stopwatch()..start());
    _photoInputClock = null;
    final cameraCaptureDone = Completer<void>();
    _cameraCaptureDone = cameraCaptureDone;
    _errorMessage = null;
    _notify();
    XFile? original;
    Uint8List? bytes;
    final stages = <String, int>{
      'inputToRequest': captureTimer.elapsedMicroseconds,
    };
    var digitalScale = 1.0;
    var capturedZoom = currentZoom;
    var capturedOrientation = controller.value.deviceOrientation.name;
    var capturedAt = DateTime.now();
    try {
      // filter와 intensity는 이 요청의 인자로 고정된다.
      await _zoomOperation;
      if (_pendingCameraControls > 0) await _cameraControlOperation;
      stages['cameraWait'] = captureTimer.elapsedMicroseconds;
      digitalScale = previewDigitalZoom;
      capturedZoom = currentZoom;
      capturedOrientation =
          controller.value.lockedCaptureOrientation?.name ??
          controller.value.deviceOrientation.name;
      capturedAt = DateTime.now();
      original = await controller.takePicture();
      stages['sensorCapture'] =
          captureTimer.elapsedMicroseconds - stages['cameraWait']!;
      stages['captureComplete'] = captureTimer.elapsedMicroseconds;
      bytes = await original.readAsBytes();
      stages['sourceRead'] =
          captureTimer.elapsedMicroseconds - stages['captureComplete']!;
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
      lastCaptureDuration = captureTimer.elapsed;
      stages['captureReady'] = captureTimer.elapsedMicroseconds;
      if (bytes != null) _pendingSaves++;
      _isCapturing = false;
      _notify();
    }
    final job = _captureStore.create({
      'filterId': filter.id,
      'filterName': filter.name,
      'intensity': intensity,
      'frameAspectRatio': frameAspectRatio,
      'mirrorHorizontally': mirrorHorizontally,
      'digitalScale': digitalScale,
      'zoom': capturedZoom,
      'orientation': capturedOrientation,
      'capturedAt': capturedAt.toUtc().toIso8601String(),
    });
    _photoTimings[job.id] = stages;
    _photoClocks[job.id] = captureTimer;
    if (canCapture) {
      stages['nextCaptureAvailable'] = captureTimer.elapsedMicroseconds;
    }
    while (_photoTimings.length > 20) {
      final oldest = _photoTimings.keys.first;
      _photoTimings.remove(oldest);
      _photoClocks.remove(oldest);
    }
    _unstagedSources[job.id] = original.path;
    final backupClock = Stopwatch()..start();
    Object? backupError;
    StackTrace? backupStack;
    // 파일 I/O는 앞선 사진의 CPU 작업과 겹쳐 진행한다. 큰 디코딩은 여전히 한 장씩이다.
    final staging = _captureStore
        .stage(job, bytes)
        .then<void>(
          (_) {
            stages['sourceBackup'] = backupClock.elapsedMicroseconds;
            unawaited(_deleteTemporaryFile(original!.path));
            _unstagedSources.remove(job.id);
          },
          onError: (Object error, StackTrace stack) {
            backupError = error;
            backupStack = stack;
            stages['sourceBackup'] = backupClock.elapsedMicroseconds;
          },
        );
    return _queuePhoto(
      job,
      stages,
      captureTimer,
      stage: () async {
        await staging;
        if (backupError != null) {
          Error.throwWithStackTrace(
            const PhotoStorageException(
              '원본을 영구 보관하지 못했습니다. 앱을 닫지 말고 저장 공간을 확보한 뒤 재시도해 주세요.',
            ),
            backupStack!,
          );
        }
      },
    );
  }

  Future<SavedPhoto> _queuePhoto(
    PhotoCaptureJob job,
    Map<String, int> stages,
    Stopwatch captureTimer, {
    Future<void> Function()? stage,
  }) {
    final result = Completer<SavedPhoto>();
    _saving = _saving.then((_) async {
      final saveTimer = Stopwatch()..start();
      stages['queueWait'] =
          captureTimer.elapsedMicroseconds - (stages['captureReady'] ?? 0);
      try {
        final backupClock = Stopwatch()..start();
        if (stage != null) await stage();
        stages['backupAwait'] = backupClock.elapsedMicroseconds;
        var saved = await repository.retryPreparedPhoto(job.id);
        if (saved == null) {
          final settings = job.settings;
          final readClock = Stopwatch()..start();
          final input = await _captureStore.read(job);
          stages['jobRead'] = readClock.elapsedMicroseconds;
          final workerClock = Stopwatch()..start();
          final processed = await _photoProcessor.process(
            photoBytes: input,
            filterId: settings['filterId']! as String,
            intensity: (settings['intensity']! as num).toDouble(),
            frameAspectRatio: (settings['frameAspectRatio']! as num).toDouble(),
            mirrorHorizontally: settings['mirrorHorizontally']! as bool,
            digitalScale: (settings['digitalScale']! as num).toDouble(),
          );
          stages['workerRoundTrip'] = workerClock.elapsedMicroseconds;
          stages.addAll(_photoProcessor.lastTimings);
          saved = await repository.savePhoto(
            bytes: processed,
            filterName: settings['filterName']! as String,
            captureId: job.id,
          );
          latestPhotoThumbnail = _photoProcessor.lastThumbnailBytes;
        } else {
          latestPhotoThumbnail = null;
        }
        latestPhotoThumbnailId = saved.id;
        _lastSavedPhoto = saved;
        _errorMessage = null;
        stages.addAll(repository.lastSaveTimings);
        stages['totalSaved'] = captureTimer.elapsedMicroseconds;
        _failedPhotoJobs.remove(job.id);
        try {
          final cleanupClock = Stopwatch()..start();
          await _captureStore.complete(job);
          stages['cleanup'] = cleanupClock.elapsedMicroseconds;
        } catch (_) {
          // 완료한 원본 정리 실패가 앨범 성공을 실패로 바꾸지 않는다.
        }
        stages['completion'] = captureTimer.elapsedMicroseconds;
        result.complete(saved);
      } catch (error) {
        stages['failed'] = captureTimer.elapsedMicroseconds;
        _failedPhotoJobs[job.id] = job;
        final failure = error is PhotoStorageException
            ? error
            : const PhotoStorageException(
                '사진 처리·저장에 실패했습니다. 보관한 원본으로 재시도해 주세요.',
              );
        _errorMessage = failure.message;
        result.completeError(failure);
      } finally {
        saveTimer.stop();
        lastSaveDuration = saveTimer.elapsed;
        _pendingSaves--;
        if (canCapture) {
          for (final entry in _photoTimings.entries) {
            if (!entry.value.containsKey('nextCaptureAvailable')) {
              entry.value['nextCaptureAvailable'] =
                  _photoClocks[entry.key]!.elapsedMicroseconds;
            }
          }
        }
        _notify();
      }
    });
    return result.future;
  }

  /// 재시도도 같은 3장 직렬 큐를 사용한다. 앱 재시작 후의 영구 작업도 포함한다.
  Future<void> retryFailedPhotos() async {
    if (_disposed || _isCapturing || _isInitializing || _isSwitchingCamera) {
      return;
    }
    final jobs = _failedPhotoJobs.values
        .take(maxPendingSaves - _pendingSaves)
        .toList();
    final futures = <Future<void>>[];
    for (final job in jobs) {
      _failedPhotoJobs.remove(job.id);
      _pendingSaves++;
      final stages = <String, int>{'captureReady': 0};
      final clock = Stopwatch()..start();
      _photoTimings[job.id] = stages;
      _photoClocks[job.id] = clock;
      while (_photoTimings.length > 20) {
        final oldest = _photoTimings.keys.first;
        _photoTimings.remove(oldest);
        _photoClocks.remove(oldest);
      }
      final source = _unstagedSources[job.id];
      futures.add(
        _queuePhoto(
          job,
          stages,
          clock,
          stage: source == null
              ? null
              : () async {
                  await _captureStore.stage(
                    job,
                    await File(source).readAsBytes(),
                  );
                  await _deleteTemporaryFile(source);
                  _unstagedSources.remove(job.id);
                },
        ).then<void>((_) {}, onError: (Object _) {}),
      );
    }
    _notify();
    await Future.wait(futures);
  }

  static Future<void> _deleteTemporaryFile(String path) async {
    if (path.isEmpty) return;
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
        await _zoomOperation;
        await _cameraControlOperation;
        await old?.dispose();
        await _initializeCamera();
      } finally {
        _isSwitchingCamera = false;
        _notify();
      }
    });
  }

  /// 미리보기의 표시 방향 기준 0~1 좌표를 받는다.
  /// 센서 회전은 camera 플러그인이 처리하므로 여기서 다시 회전하지 않는다.
  Future<bool> focusAt(Offset point) async {
    if (!point.dx.isFinite ||
        !point.dy.isFinite ||
        point.dx < 0 ||
        point.dx > 1 ||
        point.dy < 0 ||
        point.dy > 1) {
      throw const PhotoStorageException('초점 위치가 올바르지 않습니다.');
    }
    if (!canSetFocus) return false;
    final controller = _controller!;
    _pendingCameraControls++;
    var applied = false;
    final operation = _cameraControlOperation.then((_) async {
      // 이미 수락한 초점 요청은 바로 뒤에 촬영이 시작되어도 먼저 완료한다.
      // 촬영은 아래 제어 큐를 기다린 뒤 센서 프레임을 취득한다.
      if (!identical(controller, _controller) || _disposed || _suspended) {
        return;
      }
      try {
        await controller.setFocusMode(FocusMode.auto);
        await controller.setFocusPoint(point);
        applied =
            identical(controller, _controller) && !_suspended && !_disposed;
      } catch (_) {
        if (identical(controller, _controller) && !_suspended && !_disposed) {
          throw const PhotoStorageException('이 위치에 초점을 맞추지 못했습니다. 다시 시도해 주세요.');
        }
      }
    });
    _cameraControlOperation = operation.catchError((Object _) {});
    try {
      await operation;
      return applied;
    } finally {
      _pendingCameraControls--;
    }
  }

  /// 항상 발광은 사진 캡처 때만 적용한다. torch 모드는 사용하지 않는다.
  Future<void> setFlashEnabled(bool enabled) async {
    if (enabled == _flashEnabled) return;
    if (!canToggleFlash) {
      throw const PhotoStorageException('현재 카메라에서는 플래시를 사용할 수 없습니다.');
    }
    final controller = _controller!;
    _pendingCameraControls++;
    _isFlashBusy = true;
    _notify();
    final operation = _cameraControlOperation.then((_) async {
      if (!identical(controller, _controller) || _disposed || _suspended) {
        return;
      }
      try {
        await controller.setFlashMode(
          enabled ? FlashMode.always : FlashMode.off,
        );
        if (identical(controller, _controller) && !_disposed && !_suspended) {
          _desiredFlashEnabled = enabled;
          _flashEnabled = enabled;
        }
      } on CameraException catch (error) {
        final description = '${error.code} ${error.description}'.toLowerCase();
        if (description.contains('unsupported') ||
            description.contains('not supported') ||
            description.contains('not available')) {
          _flashSupported = false;
          _flashEnabled = false;
        }
        throw const PhotoStorageException('플래시 설정을 변경하지 못했습니다. 다시 시도해 주세요.');
      } catch (_) {
        throw const PhotoStorageException('플래시 설정을 변경하지 못했습니다. 다시 시도해 주세요.');
      }
    });
    _cameraControlOperation = operation.catchError((Object _) {});
    try {
      await operation;
    } finally {
      _pendingCameraControls--;
      _isFlashBusy = false;
      _notify();
    }
  }

  static Future<bool> _loadFlashSupport(CameraDescription camera) async =>
      await const MethodChannel('aeroll/camera_capabilities')
          .invokeMethod<bool>('hasFlash', {'cameraName': camera.name}) ??
      false;

  Future<void> setZoom(double zoom) {
    if (!zoom.isFinite ||
        _disposed ||
        _suspended ||
        _isInitializing ||
        _isSwitchingCamera ||
        _isCapturing ||
        _isRecordingBusy ||
        _controller == null) {
      return Future<void>.value();
    }
    _currentZoom = zoom.clamp(_minZoom, _maxZoom);
    _notify();
    if (_isRecording) {
      _recordZoomKeyframe();
      return Future<void>.value();
    }
    _requestedZoom = _currentZoom.clamp(_nativeMinZoom, _nativeMaxZoom);
    return _zoomOperation ??= _applyLatestZoom().whenComplete(() {
      _zoomOperation = null;
    });
  }

  Future<void> _applyLatestZoom() async {
    final controller = _controller;
    while (_requestedZoom != null &&
        !_disposed &&
        !_suspended &&
        identical(controller, _controller)) {
      final requested = _requestedZoom!;
      _requestedZoom = null;
      try {
        await controller!.setZoomLevel(requested);
        if (identical(controller, _controller)) {
          _appliedNativeZoom = requested;
          _notify();
        }
      } catch (_) {
        _errorMessage = '이 카메라에서는 요청한 배율을 적용할 수 없습니다.';
        if (_currentZoom < _appliedNativeZoom) {
          _currentZoom = _appliedNativeZoom;
        }
        _notify();
      }
    }
    _requestedZoom = null;
  }

  Future<void> setVideoMode(bool enabled) {
    if (_videoMode == enabled) return Future<void>.value();
    if (_disposed ||
        _suspended ||
        _isRecording ||
        _isRecordingBusy ||
        _isCapturing ||
        _isInitializing ||
        _isSwitchingCamera) {
      return Future<void>.error(
        const PhotoStorageException('현재 작업이 끝난 뒤 촬영 모드를 변경해 주세요.'),
      );
    }
    _videoMode = enabled;
    _isSwitchingCamera = true;
    _notify();
    return _enqueue(() async {
      try {
        final old = _controller;
        _controller = null;
        _notify();
        await _zoomOperation;
        await _cameraControlOperation;
        await old?.dispose();
        await _initializeCamera();
      } finally {
        _isSwitchingCamera = false;
        _notify();
      }
    });
  }

  Future<void> startVideoRecording({
    FilmFilter filter = const FilmFilter(id: 'original', name: '원본'),
    double intensity = 1,
  }) {
    if (!intensity.isFinite || intensity < 0 || intensity > 1) {
      return Future<void>.error(
        const PhotoStorageException('필터 강도는 0~1이어야 합니다.'),
      );
    }
    if (!canStartRecording) {
      return Future<void>.error(
        const PhotoStorageException('카메라가 준비된 영상 모드에서 녹화를 시작해 주세요.'),
      );
    }
    _isRecordingBusy = true;
    _notify();
    return _enqueue(() async {
      try {
        if (_disposed || _suspended) {
          throw const PhotoStorageException('카메라가 중지되어 녹화를 시작할 수 없습니다.');
        }
        await _zoomOperation;
        // 녹화 프레임의 native 줌은 고정한다. 모든 제스처는 정확히 같은
        // 디지털 타임라인으로 미리보기와 내보내기에 적용한다.
        final base = _minZoom.clamp(_nativeMinZoom, _nativeMaxZoom);
        if ((base - _appliedNativeZoom).abs() > .0001) {
          await _controller!.setZoomLevel(base);
          _appliedNativeZoom = base;
          _notify();
        }
        _recordingFilter = filter;
        _recordingIntensity = intensity;
        _zoomKeyframes.clear();
        _recordingClock.reset();
        _zoomKeyframes.add(
          ZoomKeyframe(timeMs: 0, digitalScale: previewDigitalZoom),
        );
        await _controller!.startVideoRecording();
        _recordingClock.start();
        _isRecording = true;
        _errorMessage = null;
      } catch (error) {
        final message = error is CameraException
            ? _cameraError(error)
            : error is PhotoStorageException
            ? error.message
            : '영상 녹화를 시작하지 못했습니다.';
        _errorMessage = message;
        throw PhotoStorageException(message);
      } finally {
        _isRecordingBusy = false;
        _notify();
      }
    });
  }

  Future<SavedPhoto> stopVideoRecording() {
    if (_stoppingRecording != null) return _stoppingRecording!;
    final controller = _controller;
    if (!_isRecording || _isRecordingBusy || controller == null) {
      return Future<SavedPhoto>.error(
        const PhotoStorageException('진행 중인 녹화가 없습니다.'),
      );
    }
    return _beginStopRecording(controller);
  }

  Future<SavedPhoto> _beginStopRecording(CameraController controller) {
    _isRecordingBusy = true;
    _notify();
    return _stoppingRecording = _stopAndSaveVideo(controller).whenComplete(() {
      _stoppingRecording = null;
      _isRecordingBusy = false;
      _notify();
    });
  }

  Future<SavedPhoto> _stopAndSaveVideo(CameraController controller) async {
    try {
      final file = await controller.stopVideoRecording();
      _recordingClock.stop();
      _isRecording = false;
      _recoverableVideoPath = file.path;
      _isVideoProcessing = true;
      _notify();
      final outputPath = await _videoProcessor.process(
        inputPath: file.path,
        filter: _recordingFilter,
        intensity: _recordingIntensity,
        zoomKeyframes: List<ZoomKeyframe>.unmodifiable(_zoomKeyframes),
      );
      _recoverableVideoPath = _videoProcessor.recoverableInputPath ?? file.path;
      final saved = await repository.saveVideo(
        path: outputPath,
        filterName: '${_recordingFilter.name} 영상',
      );
      _lastSavedVideo = saved;
      _errorMessage = null;
      _recoverableVideoPath = null;
      await _deleteTemporaryFile(file.path);
      await _videoProcessor.completeSuccessfulSave();
      _notify();
      return saved;
    } catch (error) {
      _recoverableVideoPath =
          _videoProcessor.recoverableInputPath ?? _recoverableVideoPath;
      final message = error is PhotoStorageException
          ? error.message
          : error is CameraException
          ? _cameraError(error)
          : '영상 저장에 실패했습니다. 복구 가능한 녹화 파일은 보존했습니다.';
      _errorMessage = message;
      _notify();
      throw PhotoStorageException(message);
    } finally {
      _isVideoProcessing = false;
      _notify();
    }
  }

  void _recordZoomKeyframe() {
    final time = _recordingClock.elapsedMilliseconds;
    final frame = ZoomKeyframe(timeMs: time, digitalScale: previewDigitalZoom);
    if (_zoomKeyframes.isNotEmpty && _zoomKeyframes.last.timeMs == time) {
      _zoomKeyframes[_zoomKeyframes.length - 1] = frame;
    } else {
      _zoomKeyframes.add(frame);
    }
    // 장시간 녹화에서도 메모리를 제한한다. 첫/마지막 상태는 보존한다.
    if (_zoomKeyframes.length > 12000) {
      final reduced = <ZoomKeyframe>[
        for (var i = 0; i < _zoomKeyframes.length - 1; i += 2)
          _zoomKeyframes[i],
        _zoomKeyframes.last,
      ];
      _zoomKeyframes
        ..clear()
        ..addAll(reduced);
    }
  }

  Future<void> _finalizeRecordingBeforeRelease(
    CameraController? controller,
  ) async {
    try {
      if (_stoppingRecording != null) {
        await _stoppingRecording;
      } else if (_isRecording && controller != null) {
        await _beginStopRecording(controller);
      }
    } catch (_) {
      // 실패 상태와 복구 경로를 보존하되 카메라 해제는 계속한다.
    }
  }

  Future<void> suspend() {
    _suspended = true;
    _generation++;
    return _enqueue(() async {
      final controller = _controller;
      _controller = null;
      _notify();
      await _cameraCaptureDone?.future;
      await _zoomOperation;
      await _cameraControlOperation;
      await _finalizeRecordingBeforeRelease(controller);
      await controller?.dispose();
      _isRecording = false;
      _notify();
    });
  }

  Future<void> resume() => initialize();

  static CameraController _createController(
    CameraDescription description,
    bool enableAudio,
  ) => CameraController(
    description,
    ResolutionPreset.high,
    enableAudio: enableAudio,
    imageFormatGroup: ImageFormatGroup.jpeg,
  );

  static String _cameraError(CameraException error) => switch (error.code) {
    'CameraAccessDenied' => '카메라 권한이 필요합니다. 설정에서 권한을 허용해 주세요.',
    'CameraAccessDeniedWithoutPrompt' =>
      '카메라 권한이 거부되었습니다. 기기 설정에서 권한을 허용해 주세요.',
    'CameraAccessRestricted' => '이 기기에서는 카메라 접근이 제한되어 있습니다.',
    'NoCamera' => '사용 가능한 카메라가 없습니다.',
    'AudioAccessDenied' || 'AudioAccessDeniedWithoutPrompt' =>
      '영상 녹음에 마이크 권한이 필요합니다. 설정에서 권한을 허용하거나 사진 모드로 돌아가 주세요.',
    'AudioAccessRestricted' => '이 기기에서는 마이크 접근이 제한되어 있습니다.',
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
        await _zoomOperation;
        await _cameraControlOperation;
        await _finalizeRecordingBeforeRelease(controller);
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
