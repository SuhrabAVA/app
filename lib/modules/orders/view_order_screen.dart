import 'package:flutter/material.dart';

import '../production/production_details_screen.dart';
import 'order_model.dart';

/// Карточка заказа для модуля оформления.
///
/// Раньше здесь жила своя, урезанная версия просмотра: три карточки-раздела
/// и никакой информации о ходе производства. Теперь оба модуля показывают
/// одну и ту же карточку — раскладку рабочего пространства с этапами,
/// комментариями и историей заказа.
class ViewOrderDialog extends StatelessWidget {
  final OrderModel order;

  /// Открыть карточку сразу на ленте истории заказа.
  final bool showHistoryFirst;

  const ViewOrderDialog({
    super.key,
    required this.order,
    this.showHistoryFirst = false,
  });

  @override
  Widget build(BuildContext context) => ProductionDetailsScreen(
        order: order,
        showHistoryFirst: showHistoryFirst,
      );
}
