import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../orders/product_type_settings.dart';
import 'product_type_settings_shell.dart';

/// Вкладка «Блоки формы»: какие блоки формы заказа доступны оператору.
///
/// Вынесена из `product_type_settings_screen.dart` без изменения поведения —
/// экран настроек перестал помещаться в один файл, когда к нему добавилась
/// вкладка очереди этапов.
class ProductTypeFormBlocksTab extends StatefulWidget {
  const ProductTypeFormBlocksTab({
    super.key,
    required this.activeConfigId,
    required this.ensureDraft,
  });

  /// Версия, которую показываем: черновик, если он есть, иначе публикация.
  final String? activeConfigId;

  /// Создаёт черновик перед первой записью и возвращает его id.
  final EnsureDraft ensureDraft;

  @override
  State<ProductTypeFormBlocksTab> createState() =>
      _ProductTypeFormBlocksTabState();
}

class _ProductTypeFormBlocksTabState extends State<ProductTypeFormBlocksTab> {
  final SupabaseClient _sb = Supabase.instance.client;

  bool _loading = true;
  bool _busy = false;
  String? _error;
  Map<String, bool> _visibility = <String, bool>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ProductTypeFormBlocksTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Оболочка подменила версию — например, первая правка создала черновик.
    if (oldWidget.activeConfigId != widget.activeConfigId) _load();
  }

  Future<void> _load() async {
    final configId = widget.activeConfigId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final visibility =
          configId == null ? <String, bool>{} : await _readVisibility(configId);
      if (!mounted) return;
      setState(() {
        _visibility = visibility;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Не удалось загрузить настройки блоков: $e';
        _loading = false;
      });
    }
  }

  Future<Map<String, bool>> _readVisibility(String configId) async {
    final rows = await _sb
        .from('product_type_form_blocks')
        .select('block_code, is_visible')
        .eq('config_id', configId);
    final result = <String, bool>{};
    for (final row in (rows as List)) {
      final map = Map<String, dynamic>.from(row as Map);
      final code = (map['block_code'] ?? '').toString();
      if (code.isEmpty) continue;
      result[code] = map['is_visible'] != false;
    }
    return result;
  }

  /// Отсутствие строки означает «блок виден» — таблица держит только
  /// отклонения от умолчания.
  bool _isVisible(String code) => _visibility[code] ?? true;

  Future<void> _toggleBlock(OrderFormBlock block, bool visible) async {
    setState(() => _busy = true);
    try {
      final configId = await widget.ensureDraft();

      // Пишем строку всегда, в том числе при значении «виден». Удалять её на
      // true нельзя: вместе с ней ушёл бы и флаг is_required, который этот
      // экран пока не показывает, но который уже есть в схеме.
      await _sb.from('product_type_form_blocks').upsert({
        'config_id': configId,
        'block_code': block.code,
        'is_visible': visible,
      }, onConflict: 'config_id,block_code');

      if (!mounted) return;
      setState(() {
        _visibility = Map<String, bool>.from(_visibility)
          ..[block.code] = visible;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Не удалось сохранить черновик: $e'),
        backgroundColor: Colors.red.shade700,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('Повторить')),
            ],
          ),
        ),
      );
    }

    final blocks = ProductTypeSettings.instance.formBlocks;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [for (final block in blocks) _buildBlockTile(block)],
    );
  }

  Widget _buildBlockTile(OrderFormBlock block) {
    return SwitchListTile(
      title: Text(block.title),
      subtitle: block.affectsStageQueue
          ? Text(
              'При скрытии соответствующий этап не добавляется в очередь',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            )
          : null,
      value: _isVisible(block.code),
      onChanged: _busy ? null : (value) => _toggleBlock(block, value),
    );
  }
}
