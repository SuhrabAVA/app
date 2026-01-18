import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/storage_service.dart' as storage;
import 'order_details_card.dart';
import 'order_model.dart';
import 'orders_repository.dart';

class ViewOrderDialog extends StatefulWidget {
  final OrderModel order;
  const ViewOrderDialog({super.key, required this.order});

  @override
  State<ViewOrderDialog> createState() => _ViewOrderDialogState();
}

class _ViewOrderDialogState extends State<ViewOrderDialog> {
  final ScrollController _scrollController = ScrollController();
  bool _loadingFiles = false;
  List<Map<String, dynamic>> _files = const [];
  List<Map<String, dynamic>> _paints = const [];
  String? _stageTemplateName;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadingFiles = true);
    try {
      final repo = OrdersRepository();
      final paints = await repo.getPaints(widget.order.id);
      final files = await storage.listOrderFiles(widget.order.id);
      String? stageTemplateName;
      final tplId = widget.order.stageTemplateId;
      if (tplId != null && tplId.isNotEmpty) {
        final tpl = await Supabase.instance.client
            .from('plan_templates')
            .select('name')
            .eq('id', tplId)
            .maybeSingle();
        final name = tpl?['name']?.toString();
        if (name != null && name.isNotEmpty) stageTemplateName = name;
      }
      setState(() {
        _paints = paints;
        _files = files;
        _stageTemplateName = stageTemplateName;
      });
    } catch (_) {
      // ignore errors in read-only view
    } finally {
      if (mounted) setState(() => _loadingFiles = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    final size = MediaQuery.of(context).size;
    final dialogHeight = size.height - 32;
    final dialogWidth = math.min(size.width - 32, 1100.0);

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: dialogHeight,
          maxWidth: dialogWidth,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Заказ ${o.assignmentId ?? o.id}',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Обновить данные',
                    onPressed: _loadingFiles ? null : _load,
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Scrollbar(
                controller: _scrollController,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  child: Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: OrderDetailsCard(
                        order: o,
                        paints: _paints,
                        files: _files,
                        loadingFiles: _loadingFiles,
                        stageTemplateName: _stageTemplateName,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
