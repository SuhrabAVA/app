import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../orders/product_type_settings.dart';

/// Редактор настроек типа продукта. Пока одна вкладка — «Блоки формы».
///
/// МОДЕЛЬ ЧЕРНОВИКА
/// Правка многошаговая, поэтому она не действует, пока техлид её не опубликует.
/// При первом переключателе создаётся черновик копированием текущей
/// опубликованной версии; приложение продолжает читать опубликованную.
///
/// Два случая, ради которых черновик ищется в базе, а не заводится заново:
///   * техлид ушёл, не опубликовав — при следующем открытии черновик
///     ПОДХВАТЫВАЕТСЯ (_loadState ищет status='draft'), второй не создаётся;
///   * техлид передумал — кнопка «Отменить изменения» удаляет черновик, и
///     экран возвращается к опубликованной версии.
class ProductTypeSettingsScreen extends StatefulWidget {
  const ProductTypeSettingsScreen({super.key, required this.productType});

  final ProductTypeRef productType;

  @override
  State<ProductTypeSettingsScreen> createState() =>
      _ProductTypeSettingsScreenState();
}

class _ProductTypeSettingsScreenState extends State<ProductTypeSettingsScreen> {
  final SupabaseClient _sb = Supabase.instance.client;

  bool _loading = true;
  bool _busy = false;
  String? _error;

  List<OrderFormBlock> _blocks = const <OrderFormBlock>[];
  ProductTypeConfig? _published;
  ProductTypeConfig? _draft;

  /// Значения, показанные на экране: черновик, если он есть, иначе публикация.
  Map<String, bool> _visibility = <String, bool>{};

  bool get _hasDraft => _draft != null;

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

      final active = draft ?? published;
      final visibility =
          active == null ? <String, bool>{} : await _readVisibility(active.id);

      if (!mounted) return;
      setState(() {
        _blocks = ProductTypeSettings.instance.formBlocks;
        _published = published;
        _draft = draft;
        _visibility = visibility;
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

  /// Создаёт черновик копированием опубликованной версии.
  Future<ProductTypeConfig> _createDraft() async {
    final versions = await _sb
        .from('product_type_configs')
        .select('version')
        .eq('product_type_id', widget.productType.id)
        .order('version', ascending: false)
        .limit(1);
    final maxVersion = (versions as List).isEmpty
        ? 0
        : ((Map<String, dynamic>.from(versions.first as Map)['version']
                    as num?)
                ?.toInt() ??
            0);

    final inserted = await _sb
        .from('product_type_configs')
        .insert({
          'product_type_id': widget.productType.id,
          'version': maxVersion + 1,
          'status': ProductTypeConfig.statusDraft,
          'note': 'Черновик правки настроек блоков формы.',
        })
        .select('id, product_type_id, version, status')
        .single();

    final draft =
        ProductTypeConfig.fromMap(Map<String, dynamic>.from(inserted))!;

    // Копируем настройки опубликованной версии, чтобы черновик стартовал с
    // текущего состояния, а не с пустого.
    final source = _published;
    if (source != null) {
      final rows = await _sb
          .from('product_type_form_blocks')
          .select('block_code, is_visible, is_required')
          .eq('config_id', source.id);
      final copies = <Map<String, dynamic>>[
        for (final row in (rows as List))
          {
            'config_id': draft.id,
            'block_code':
                Map<String, dynamic>.from(row as Map)['block_code'],
            'is_visible':
                Map<String, dynamic>.from(row)['is_visible'] != false,
            'is_required':
                Map<String, dynamic>.from(row)['is_required'] == true,
          },
      ];
      if (copies.isNotEmpty) {
        await _sb.from('product_type_form_blocks').insert(copies);
      }
    }
    return draft;
  }

  Future<void> _toggleBlock(OrderFormBlock block, bool visible) async {
    setState(() => _busy = true);
    try {
      var draft = _draft;
      draft ??= await _createDraft();

      // Пишем строку всегда, в том числе при значении «виден». Удалять её на
      // true нельзя: вместе с ней ушёл бы и флаг is_required, который этот
      // экран пока не показывает, но который уже есть в схеме.
      await _sb.from('product_type_form_blocks').upsert({
        'config_id': draft.id,
        'block_code': block.code,
        'is_visible': visible,
      }, onConflict: 'config_id,block_code');

      if (!mounted) return;
      setState(() {
        _draft = draft;
        _visibility = Map<String, bool>.from(_visibility)
          ..[block.code] = visible;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showError('Не удалось сохранить черновик: $e');
    }
  }

  Future<void> _publish() async {
    final draft = _draft;
    if (draft == null) return;
    setState(() => _busy = true);
    try {
      // Публикация идёт одним вызовом RPC, а не двумя update.
      // Частичный уникальный индекс допускает только одну опубликованную
      // версию на тип продукта, поэтому прежнюю обязательно архивировать ДО
      // публикации черновика. Двумя запросами обрыв между шагами оставлял бы
      // тип продукта вообще без опубликованной версии — настройки молча
      // переставали бы действовать. publish_product_type_config делает оба
      // шага в одной транзакции и сама проверяет, что публикуется черновик.
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
      _showError(
        'Не удалось опубликовать настройки: $e. '
        'Черновик сохранён, попробуйте ещё раз.',
      );
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
      // Строки product_type_form_blocks уходят каскадом вместе с версией.
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
    // Вкладка пока одна, но TabBar оставлен: следующая фаза добавит сюда
    // «Этапы» и «Условия», и структура экрана не поменяется.
    return DefaultTabController(
      length: 1,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.productType.title),
          bottom: const TabBar(
            tabs: [Tab(text: 'Блоки формы')],
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

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
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
        for (final block in _blocks) _buildBlockTile(block),
      ],
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
      onChanged:
          _busy ? null : (value) => _toggleBlock(block, value),
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
