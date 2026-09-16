import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../orders/product_type_settings.dart';
import 'personnel_list_controls.dart';
import 'personnel_list_filters.dart';
import 'product_type_settings_shell.dart';

/// Список типов продукта с точкой входа в редактор настроек.
///
/// Складской хаб категорий (`categories_hub_screen.dart`) намеренно не трогаем:
/// он про позиции на складе, у него своё меню «Переименовать / Удалить», и
/// производственные настройки там не к месту.
class ProductTypesScreen extends StatefulWidget {
  const ProductTypesScreen({super.key});

  @override
  State<ProductTypesScreen> createState() => _ProductTypesScreenState();
}

class _ProductTypesScreenState extends State<ProductTypesScreen> {
  final SupabaseClient _sb = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  List<ProductTypeRef> _types = const <ProductTypeRef>[];

  /// product_type_id → есть неопубликованный черновик настроек.
  Set<String> _typesWithDraft = <String>{};

  final ProductTypeListFilter _filter = ProductTypeListFilter();
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _reset() {
    _search.clear();
    setState(_filter.clear);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ProductTypeSettings.instance.ensureLoaded(force: true);
      final drafts = await _sb
          .from('product_type_configs')
          .select('product_type_id')
          .eq('status', ProductTypeConfig.statusDraft);
      if (!mounted) return;
      setState(() {
        _types = ProductTypeSettings.instance.productTypes;
        _typesWithDraft = <String>{
          for (final row in (drafts as List))
            (Map<String, dynamic>.from(row as Map)['product_type_id'] ?? '')
                .toString(),
        }..remove('');
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Не удалось загрузить типы продукта: $e';
        _loading = false;
      });
    }
  }

  Future<void> _openSettings(ProductTypeRef type) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ProductTypeSettingsShell(productType: type),
      ),
    );
    if (!mounted) return;
    // Маркер черновика и кэш настроек могли измениться на том экране.
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Типы продукта'),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
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
    if (_types.isEmpty) {
      return const Center(child: Text('Типы продукта не заведены.'));
    }

    final types = _types
        .where((t) =>
            _filter.matches(t, draft: _typesWithDraft.contains(t.id)))
        .toList();

    return Column(
      children: [
        PersonnelFilterBar(
          controller: _search,
          hint: 'Название типа продукта…',
          onQueryChanged: (v) => setState(() => _filter.query = v),
          shown: types.length,
          total: _types.length,
          isActive: _filter.isActive,
          onReset: _reset,
          filters: [
            TriFilterChip(
              label: 'Черновик',
              value: _filter.hasDraft,
              onChanged: (v) => setState(() => _filter.hasDraft = v),
            ),
          ],
        ),
        Expanded(
          child: types.isEmpty
              ? PersonnelEmptyResult(
                  isFiltered: _filter.isActive,
                  emptyText: 'Типы продукта не заведены.',
                  onReset: _reset,
                )
              : _buildList(types),
        ),
      ],
    );
  }

  Widget _buildList(List<ProductTypeRef> types) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: types.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final type = types[i];
        final hasDraft = _typesWithDraft.contains(type.id);
        return ListTile(
          title: Text(type.title),
          subtitle: hasDraft
              ? const Text(
                  'Есть неопубликованный черновик',
                  style: TextStyle(color: Color(0xFFB26A00)),
                )
              : null,
          onTap: () => _openSettings(type),
          trailing: IconButton(
            tooltip: 'Настройки типа продукта',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _openSettings(type),
          ),
        );
      },
    );
  }
}
