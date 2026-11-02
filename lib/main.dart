import 'package:flutter/material.dart';

import 'controllers/camera_session.dart';
import 'screens/camera_screen.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.session});

  final CameraSession? session;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'AeRoll',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light,
    home: CameraScreen(session: session),
  );
}
