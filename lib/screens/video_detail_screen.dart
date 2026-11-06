import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/saved_photo.dart';
import '../theme/app_theme.dart';
import 'photo_detail_screen.dart';

class VideoDetailScreen extends StatefulWidget {
  const VideoDetailScreen({
    super.key,
    required this.video,
    this.controllerFactory,
  });
  final SavedPhoto video;
  final VideoPlayerController Function(File file)? controllerFactory;

  @override
  State<VideoDetailScreen> createState() => _VideoDetailScreenState();
}

class _VideoDetailScreenState extends State<VideoDetailScreen>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _loading = true;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadVideo());
  }

  Future<void> _loadVideo() async {
    final generation = ++_generation;
    final old = _controller;
    _controller = null;
    setState(() {
      _loading = true;
      _error = null;
    });
    if (old != null) unawaited(old.dispose().catchError((Object _) {}));
    VideoPlayerController? next;
    try {
      next =
          widget.controllerFactory?.call(File(widget.video.path)) ??
          VideoPlayerController.file(File(widget.video.path));
      _controller = next;
      await next.initialize();
      if (!mounted || generation != _generation) return;
      setState(() => _loading = false);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = '동영상을 재생할 수 없어요. 파일이 이동되거나 지원하지 않는 형식일 수 있어요.\n$error';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(
        _controller?.pause().catchError((Object _) {}) ?? Future<void>.value(),
      );
    }
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      if (controller.value.isPlaying) {
        await controller.pause();
      } else {
        if (controller.value.position >= controller.value.duration) {
          await controller.seekTo(Duration.zero);
        }
        await controller.play();
      }
    } catch (error) {
      if (mounted) setState(() => _error = '재생 중 오류가 발생했어요.\n$error');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    final controller = _controller;
    if (controller != null) {
      unawaited(controller.dispose().catchError((Object _) {}));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppTheme.ink,
    appBar: AppBar(
      title: const Text('한 편의 순간'),
      backgroundColor: AppTheme.ink,
      foregroundColor: AppTheme.paper,
    ),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(child: _buildPlayer()),
          Flexible(
            flex: 0,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.video.filterName,
                    style: TextStyle(color: AppTheme.paper, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    formatPhotoDate(widget.video.createdAt),
                    style: const TextStyle(color: AppTheme.paper, fontSize: 12),
                  ),
                  if (!widget.video.isInDeviceAlbum)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        '기기 앨범 저장에 실패하여 앱 사본만 보관 중이에요.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.amber, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _buildPlayer() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(
          key: Key('video-loading'),
          color: Colors.white,
          semanticsLabel: '동영상 불러오는 중',
        ),
      );
    }
    final controller = _controller;
    if (_error != null || controller == null) {
      return _buildError(_error ?? '동영상을 불러오지 못했어요.');
    }
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        if (value.hasError) {
          return _buildError(
            '동영상을 재생할 수 없어요.\n${value.errorDescription ?? ''}',
          );
        }
        return Column(
          children: [
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: value.aspectRatio > 0
                      ? value.aspectRatio
                      : 16 / 9,
                  child: VideoPlayer(controller),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: VideoProgressIndicator(
                controller,
                allowScrubbing: true,
                colors: const VideoProgressColors(
                  playedColor: Colors.white,
                  bufferedColor: Colors.white38,
                  backgroundColor: Colors.white12,
                ),
              ),
            ),
            IconButton(
              key: const Key('video-play-pause'),
              tooltip: value.isPlaying ? '동영상 일시정지' : '동영상 재생',
              onPressed: _togglePlayback,
              color: Colors.white,
              iconSize: 40,
              icon: Icon(
                value.isPlaying
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildError(String message) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.videocam_off_outlined,
            color: Colors.white70,
            size: 40,
          ),
          const SizedBox(height: 16),
          Text(
            message,
            key: const Key('video-error'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, height: 1.6),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _loadVideo,
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
            child: const Text('다시 불러오기'),
          ),
        ],
      ),
    ),
  );
}
