// lib/modules/personnel/dialog_utils.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'personnel_provider.dart';

/// Универсальный вызов диалога, который ПЕРЕД показом гарантированно
/// подтягивает актуальный список должностей из БД.
/// Используй для форм: «Новое/Изменить рабочее место», (и при необходимости — терминалы).
Future<T?> showDialogWithFreshPositions<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) async {
  try {
    // важно: получаем свежие должности прямо перед построением чипов
    await context.read<PersonnelProvider>().fetchPositions();
  } catch (_) {
    // даже если сеть/RLS — не блокируем открытие диалога
  }
  if (!context.mounted) return null;

  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: builder,
  );
}
