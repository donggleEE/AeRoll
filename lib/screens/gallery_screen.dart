import 'dart:io';

import 'package:flutter/material.dart';

import '../models/saved_photo.dart';
import '../services/photo_repository.dart';
import '../theme/app_theme.dart';
import 'photo_detail_screen.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key, required this.repository});
  final PhotoRepository repository;

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  late Future<List<SavedPhoto>> _photos;

  @override
  void initState() {
    super.initState();
    _photos = widget.repository.listPhotos();
  }

  void _reload() {
    setState(() {
      _photos = widget.repository.listPhotos();
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('나의 필름'),
      actions: [
        IconButton(
          tooltip: '사진 새로고침',
          onPressed: _reload,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: FutureBuilder<List<SavedPhoto>>(
      future: _photos,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(semanticsLabel: '사진 불러오는 중'),
          );
        }
        if (snapshot.hasError) {
          return _GalleryMessage(
            icon: Icons.error_outline,
            title: '사진을 불러오지 못했어요',
            message: '잠시 후 다시 시도해 주세요.\n${snapshot.error}',
            buttonLabel: '다시 불러오기',
            onPressed: _reload,
          );
        }
        final photos = snapshot.data ?? [];
        if (photos.isEmpty) {
          return _GalleryMessage(
            icon: Icons.photo_library_outlined,
            title: '첫 번째 순간을 담아볼까요?',
            message: '촬영한 사진이 이곳에 차곡차곡 쌓여요.',
            buttonLabel: '사진 찍으러 가기',
            onPressed: () => Navigator.of(context).pop(),
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            _reload();
            try {
              await _photos;
            } catch (_) {
              /* 오류는 FutureBuilder에서 안내한다. */
            }
          },
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: Text(
                    '${photos.length}장의 순간 · 최근 촬영순\n앱에 보관한 사진은 기기 앨범과 별도로 유지돼요.',
                    style: const TextStyle(color: AppTheme.muted),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                sliver: SliverGrid.builder(
                  itemCount: photos.length,
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 240,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 5 / 6,
                  ),
                  itemBuilder: (context, index) {
                    final photo = photos[index];
                    return Semantics(
                      button: true,
                      label:
                          '${photo.filterName}, ${formatPhotoDate(photo.createdAt)} 사진 열기',
                      child: Material(
                        color: AppTheme.line,
                        borderRadius: BorderRadius.circular(12),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) => PhotoDetailScreen(photo: photo),
                            ),
                          ),
                          child: Hero(
                            tag: 'photo-${photo.id}',
                            child: Image.file(
                              File(photo.path),
                              fit: BoxFit.cover,
                              cacheWidth: 480,
                              excludeFromSemantics: true,
                              errorBuilder: (_, _, _) => const Center(
                                child: Icon(
                                  Icons.broken_image_outlined,
                                  color: AppTheme.muted,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _GalleryMessage extends StatelessWidget {
  const _GalleryMessage({
    required this.icon,
    required this.title,
    required this.message,
    required this.buttonLabel,
    required this.onPressed,
  });
  final IconData icon;
  final String title;
  final String message;
  final String buttonLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 52, color: AppTheme.muted),
          const SizedBox(height: 24),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.muted, height: 1.6),
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: onPressed, child: Text(buttonLabel)),
        ],
      ),
    ),
  );
}
