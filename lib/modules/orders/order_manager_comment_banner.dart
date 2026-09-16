import 'package:flutter/material.dart';

import '../tasks/workspace_design.dart';

/// Комментарий менеджера к заказу («Комментарии к заказу» в форме).
///
/// Стоит отдельным красным блоком над карточкой заказа, а не строкой внутри
/// «Бобинорезки»: там его пролистывали, хотя в нём самое важное для цеха.
/// Пустой комментарий блока не создаёт.
class OrderManagerCommentBanner extends StatelessWidget {
  const OrderManagerCommentBanner({super.key, required this.comment});

  static const Color background = Color(0xFFA80006);

  final String comment;

  static bool hasComment(String comment) => comment.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final text = comment.trim();
    if (text.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: workspaceCardDecoration(
        color: background,
        withBorder: false,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(6),
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.priority_high_rounded,
                  size: 14,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 7),
              const Expanded(
                child: Text(
                  'КОММЕНТАРИЙ',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 9.5,
                    height: 1.1,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.35,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              height: 1.35,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
