import 'package:flutter/material.dart';

import 'app_ui_stability.dart';
import 'login_screen.dart';
import 'utils/enter_key_behavior.dart';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appTheme,
      builder: (context, child) => EnterKeyBehavior(
        child: child ?? const SizedBox.shrink(),
      ),
      home: const LoginScreen(),
    );
  }
}
