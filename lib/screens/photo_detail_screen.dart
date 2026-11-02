import 'dart:io';

import 'package:flutter/material.dart';

import '../models/saved_photo.dart';
import '../theme/app_theme.dart';

String formatPhotoDate(DateTime date) {
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}.${two(local.month)}.${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

class PhotoDetailScreen extends StatelessWidget {
  const PhotoDetailScreen({super.key, required this.photo});
  final SavedPhoto photo;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppTheme.ink,
    appBar: AppBar(
      title: const Text('한 장의 순간'),
      backgroundColor: AppTheme.ink,
      foregroundColor: AppTheme.paper,
    ),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: Center(
                child: Hero(
                  tag: 'photo-${photo.id}',
                  child: Image.file(
                    File(photo.path),
                    fit: BoxFit.contain,
                    semanticLabel: '${photo.filterName} 필터로 촬영한 사진',
                    errorBuilder: (_, _, _) => const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '사진 파일을 읽을 수 없어요.\n사진이 이동되거나 삭제되었을 수 있어요.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppTheme.paper, height: 1.6),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Flexible(
            flex: 0,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    photo.filterName,
                    style: const TextStyle(
                      color: AppTheme.paper,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    formatPhotoDate(photo.createdAt),
                    style: const TextStyle(color: AppTheme.paper, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '두 손가락으로 사진을 확대해 보세요',
                    style: TextStyle(color: AppTheme.paper, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
