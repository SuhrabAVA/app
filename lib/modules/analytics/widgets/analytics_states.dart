import 'package:flutter/material.dart';

import '../utils/analytics_colors.dart';

class AnalyticsLoadingState extends StatelessWidget {
  const AnalyticsLoadingState({super.key, this.label = 'Загружаем аналитику…'});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: AnalyticsColors.blue),
          const SizedBox(height: 14),
          Text(label, style: const TextStyle(color: AnalyticsColors.muted)),
        ],
      ),
    );
  }
}

class AnalyticsEmptyState extends StatelessWidget {
  const AnalyticsEmptyState({super.key, required this.message, this.icon});
  final String message;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon ?? Icons.inbox_outlined,
              size: 56, color: AnalyticsColors.muted2),
          const SizedBox(height: 12),
          Text(
            message,
            style: const TextStyle(color: AnalyticsColors.muted, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class AnalyticsErrorState extends StatelessWidget {
  const AnalyticsErrorState({
    super.key,
    required this.message,
    this.onRetry,
  });
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                color: AnalyticsColors.red, size: 56),
            const SizedBox(height: 12),
            Text(
              message,
              style: const TextStyle(color: AnalyticsColors.text, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              FilledButton(
                onPressed: onRetry,
                child: const Text('Повторить'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class AnalyticsAccessDeniedState extends StatelessWidget {
  const AnalyticsAccessDeniedState({super.key});
  @override
  Widget build(BuildContext context) {
    return const AnalyticsErrorState(
      message: 'У вас нет доступа к этому разделу',
    );
  }
}
