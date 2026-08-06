import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../orders/product_type_settings.dart';
import 'product_type_form_blocks_tab.dart';
import 'product_type_stages_tab.dart';

/// Создаёт черновик, если его ещё нет, и возвращает id версии для записи.
typedef EnsureDraft = Future<String> Function();

/// Оболочка редактора настроек типа продукта.
///
/// Держит состояние версии и нижнюю панель черновика; вкладки занимаются
/// только своим содержимым.
///
/// МОДЕЛЬ ЧЕРНОВИКА
/// Правка многошаговая, поэтому она не действует, пока техлид её не
/// опубликует. Каждый жест пишется в черновик сразу — это безопасно по
/// построению: черновик никем не читается, пока не опубликован. Диффовать
/// большую модель в памяти против базы не нужно.
///
/// Два случая, ради которых черновик ищется в базе, а не заводится заново:
///   * техлид ушёл, не опубликовав — при следующем открытии черновик
///     ПОДХВАТЫВАЕТСЯ, второй не создаётся (за это же отвечает и
///     идемпотентность create_product_type_config_draft);
///   * техлид передумал — «Отменить изменения» удаляет черновик, и экран
///     возвращается к опубликованной версии.
class ProductTypeSettingsShell extends StatefulWidget {
  const ProductTypeSettingsShell({super.key, required this.productType});

  final ProductTypeRef productType;

  @override
  State<ProductTypeSettingsShell> createState() =>
      _ProductTypeSettingsShellState();
}

class _ProductTypeSettingsShellState extends State<ProductTypeSettingsShell> {
  final SupabaseClient _sb = Supabase.instance.client;

  bool _loading = true;
  bool _busy = false;
  String? _error;

  ProductTypeConfig? _draft;
  ProductTypeConfig? _published;

  bool get _hasDraft => _draft != null;

  /// Версия, которую показывают вкладки: черновик, если есть, иначе публикация.
  String? get _activeConfigId => (_draft ?? _published)?.id;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ProductTypeSettings.instance.ensureLoaded();
      final configs = await _sb
          .from('product_type_configs')
          .select('id, product_type_id, version, status')
          .eq('product_type_id', widget.productType.id)
          .order('version');

      ProductTypeConfig? published;
      ProductTypeConfig? draft;
      for (final row in (configs as List)) {
        final config =
            ProductTypeConfig.fromMap(Map<String, dynamic>.from(row as Map));
        if (config == null) continue;
        if (config.isPublished) published = config;
        // Черновиков теоретически может быть несколько; берём последний по
        // версии — сортировка выше это гарантирует.
        if (config.isDraft) draft = config;
      }

      if (!mounted) return;
      setState(() {
        _published = published;
        _draft = draft;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Не удалось загрузить настройки: $e';
        _loading = false;
      });
    }
  }

  /// Глубокая копия опубликованной версии одной транзакцией.
  ///
  /// Копирует блоки формы, этапы обоих уровней, их рабочие места и условия,
  /// перекладывая parent_variant_id на новые id вариантов. Идемпотентна: если
  /// черновик уже есть, вернёт его.
  Future<String> _ensureDraft() async {
    final existing = _draft;
    if (existing != null) return existing.id;

    final draftId = await _sb.rpc(
      'create_product_type_config_draft',
      params: {'p_product_type_id': widget.productType.id},
    );
    await _loadState();
    return draftId.toString();
  }

  Future<void> _publish() async {
    final draft = _draft;
    if (draft == null) return;
    setState(() => _busy = true);
    try {
      // Публикация идёт одним вызовом RPC: она же проверяет структуру
      // маршрута через validate_product_type_config и отказывается выпускать
      // битую версию.
      await _sb.rpc(
        'publish_product_type_config',
        params: {'p_config_id': draft.id},
      );

      ProductTypeSettings.instance.invalidate();
      await ProductTypeSettings.instance.ensureLoaded();

      if (!mounted) return;
      setState(() => _busy = false);
      _showInfo('Настройки опубликованы.');
      await _loadState();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showError('$e');
      await _loadState();
    }
  }

  Future<void> _discardDraft() async {
    final draft = _draft;
    if (draft == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Отменить изменения?'),
        content: const Text(
          'Черновик будет удалён, настройки вернутся к опубликованной версии.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Нет'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить черновик'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      // Этапы, рабочие места, условия и блоки формы уходят каскадом.
      await _sb.from('product_type_configs').delete().eq('id', draft.id);
      if (!mounted) return;
      setState(() => _busy = false);
      await _loadState();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showError('Не удалось удалить черновик: $e');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red.shade700),
    );
  }

  void _showInfo(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.productType.title),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Блоки формы'),
              Tab(text: 'Очередь этапов'),
            ],
          ),
        ),
        body: _buildBody(),
        bottomNavigationBar: _hasDraft ? _buildDraftBar() : null,
      ),
    );
  }

  Widget _buildBody() {
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
              FilledButton(
                onPressed: _loadState,
                child: const Text('Повторить'),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        if (_hasDraft)
          Container(
            width: double.infinity,
            color: const Color(0xFFFFF4DE),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: const Text(
              'Черновик не опубликован. Заказы пока собираются по прежним '
              'настройкам.',
              style: TextStyle(color: Color(0xFF8A5A00)),
            ),
          ),
        Expanded(
          child: TabBarView(
            children: [
              ProductTypeFormBlocksTab(
                activeConfigId: _activeConfigId,
                ensureDraft: _ensureDraft,
              ),
              ProductTypeStagesTab(
                productType: widget.productType,
                activeConfigId: _activeConfigId,
                isDraft: _hasDraft,
                ensureDraft: _ensureDraft,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDraftBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : _discardDraft,
                child: const Text('Отменить изменения'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _busy ? null : _publish,
                child: const Text('Опубликовать'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
