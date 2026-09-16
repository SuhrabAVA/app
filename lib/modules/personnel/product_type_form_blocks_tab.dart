import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../orders/product_type_condition_options.dart';
import '../orders/product_type_settings.dart';
import 'product_type_block_condition_dialog.dart';
import 'product_type_design.dart';

/// Вкладка «Блоки формы»: какие блоки формы заказа доступны оператору.
///
/// Вынесена из `product_type_settings_screen.dart` без изменения поведения —
/// экран настроек перестал помещаться в один файл, когда к нему добавилась
/// вкладка очереди этапов.
class ProductTypeFormBlocksTab extends StatefulWidget {
  const ProductTypeFormBlocksTab({
    super.key,
    required this.activeConfigId,
    required this.isDraft,
  });

  /// Версия, которую показываем: черновик, если он есть, иначе публикация.
  final String? activeConfigId;

  /// Есть ли черновик. Правки без него не бывает — её включает кнопка
  /// «Начать правку» в оболочке.
  final bool isDraft;

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

  /// block_code → is_required. Отсутствие ключа = не обязателен.
  Map<String, bool> _required = <String, bool>{};

  /// block_code → условие обязательности. Отсутствие ключа = «всегда».
  ///
  /// Схема допускает несколько условий на блок (AND), редактор показывает
  /// одно — по тому же решению, что и у этапов: список остаётся заделом,
  /// а второе условие в интерфейсе сразу потребовало бы скобок.
  Map<String, OrderBlockCondition> _conditions =
      <String, OrderBlockCondition>{};

  /// Таблица условий доступна. false — миграция ещё не применена.
  bool _conditionsAvailable = true;

  /// Версия, ИЗ КОТОРОЙ реально загружены показанные значения.
  ///
  /// Правку включаем только когда она совпала с текущей и это черновик:
  /// пока перезагрузка после создания черновика не завершилась, в состоянии
  /// лежат данные опубликованной версии, и писать по ним нельзя.
  String? _loadedConfigId;

  bool get _canEdit =>
      widget.isDraft &&
      !_loading &&
      !_busy &&
      _loadedConfigId != null &&
      _loadedConfigId == widget.activeConfigId;

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
      final rows = configId == null
          ? const <Map<String, dynamic>>[]
          : await _readSettings(configId);
      final conditionRows = configId == null
          ? const <Map<String, dynamic>>[]
          : await _readConditions(configId);
      if (!mounted) return;
      setState(() {
        _visibility = <String, bool>{
          for (final row in rows)
            if ((row['block_code'] ?? '').toString().isNotEmpty)
              (row['block_code'] as String): row['is_visible'] != false,
        };
        _required = <String, bool>{
          for (final row in rows)
            if ((row['block_code'] ?? '').toString().isNotEmpty)
              (row['block_code'] as String): row['is_required'] == true,
        };
        _conditions = <String, OrderBlockCondition>{
          for (final row in conditionRows)
            if (OrderBlockCondition.tryFromMap(row) case final condition?)
              (row['block_code'] ?? '').toString(): condition,
        }..remove('');
        _loadedConfigId = configId;
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

  Future<List<Map<String, dynamic>>> _readSettings(String configId) async {
    final rows = await _sb
        .from('product_type_form_blocks')
        .select('block_code, is_visible, is_required')
        .eq('config_id', configId);
    return <Map<String, dynamic>>[
      for (final row in (rows as List)) Map<String, dynamic>.from(row as Map),
    ];
  }

  /// Отсутствие строки означает «блок виден» — таблица держит только
  /// отклонения от умолчания.
  bool _isVisible(String code) => _visibility[code] ?? true;

  /// Умолчание обратное: новый блок в справочнике не должен задним числом
  /// уронить в черновики все заказы типа продукта.
  bool _isRequired(String code) => _required[code] ?? false;

  /// Условия блоков; пустой список — таблицы в базе ещё нет.
  ///
  /// Вкладка обязана открываться и без неё: видимость и обязательность живут в
  /// другой таблице, и терять их из-за не доехавшей миграции незачем. Признак
  /// [_conditionsAvailable] гасит только строку условия.
  Future<List<Map<String, dynamic>>> _readConditions(String configId) async {
    try {
      final rows = await _sb
          .from('product_type_form_block_conditions')
          .select('block_code, predicate, negate, param_text')
          .eq('config_id', configId);
      _conditionsAvailable = true;
      return <Map<String, dynamic>>[
        for (final row in (rows as List)) Map<String, dynamic>.from(row as Map),
      ];
    } catch (e) {
      _conditionsAvailable = false;
      return const <Map<String, dynamic>>[];
    }
  }

  /// Заменяет условие блока целиком.
  ///
  /// Сначала удаление, потом вставка — а не upsert: строк на блок может быть
  /// несколько (схема это допускает), и точечная правка одной из них оставила
  /// бы остальные висеть невидимыми для редактора требованиями.
  Future<void> _editCondition(OrderFormBlock block) async {
    final configId = widget.activeConfigId;
    if (!_canEdit || configId == null) return;

    final choice = await showBlockConditionDialog(
      context: context,
      blockTitle: block.title,
      current: _conditions[block.code],
    );
    if (choice == null || !mounted) return;

    setState(() => _busy = true);
    try {
      await _sb
          .from('product_type_form_block_conditions')
          .delete()
          .eq('config_id', configId)
          .eq('block_code', block.code);
      final condition = choice.condition;
      if (condition != null) {
        await _sb.from('product_type_form_block_conditions').insert({
          'config_id': configId,
          'block_code': block.code,
          'predicate': condition.predicate,
          'negate': condition.negate,
          if (condition.param != null) 'param_text': condition.param,
        });
      }
      if (!mounted) return;
      setState(() {
        final next = Map<String, OrderBlockCondition>.from(_conditions);
        if (condition == null) {
          next.remove(block.code);
        } else {
          next[block.code] = condition;
        }
        _conditions = next;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Не удалось сохранить условие: $e'),
        backgroundColor: Colors.red.shade700,
      ));
    }
  }

  Future<void> _toggleBlock(OrderFormBlock block, bool visible) {
    // Скрытый блок обязательным не бывает: поля в форме нет, заполнить нечем,
    // и заказ заперло бы в черновике навсегда. Снимаем требование вместе с
    // видимостью, а не оставляем висеть мёртвой строкой.
    return _write(
      block,
      visible: visible,
      required: visible && _isRequired(block.code),
    );
  }

  Future<void> _toggleRequired(OrderFormBlock block, bool required) =>
      _write(block, visible: _isVisible(block.code), required: required);

  Future<void> _write(
    OrderFormBlock block, {
    required bool visible,
    required bool required,
  }) async {
    // Двойная защита: контролы уже неактивны, но запись без подтверждённого
    // черновика не должна быть возможна и программно.
    final configId = widget.activeConfigId;
    if (!_canEdit || configId == null) return;
    setState(() => _busy = true);
    try {
      // Пишем строку всегда, в том числе при значении «виден»: удалить её —
      // значит потерять заодно и флаг обязательности.
      await _sb.from('product_type_form_blocks').upsert({
        'config_id': configId,
        'block_code': block.code,
        'is_visible': visible,
        'is_required': required,
      }, onConflict: 'config_id,block_code');

      if (!mounted) return;
      setState(() {
        _visibility = Map<String, bool>.from(_visibility)
          ..[block.code] = visible;
        _required = Map<String, bool>.from(_required)..[block.code] = required;
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
    return LayoutBuilder(
      builder: (context, constraints) {
        // Две колонки на широком экране, одна — на планшете в портрете.
        final columns = constraints.maxWidth >= 720 ? 2 : 1;
        return ListView(
          padding: const EdgeInsets.all(PtMetrics.pagePadding),
          children: [
            const PtSectionHeader(
              icon: Icons.tune_rounded,
              label: 'Блоки заказа',
            ),
            const Text(
              'Переключатель слева — показывать ли блок при создании заказа '
              'этого типа. Выключенный блок в форме не появляется вовсе, а '
              'если он влияет на маршрут — соответствующий этап не попадает в '
              'очередь. '
              'Галочка «Обязателен» — без этого блока заказ не уйдёт в «Готов '
              'к запуску» и останется черновиком, пока его не заполнят.',
              style: TextStyle(fontSize: 13, color: PtColors.muted, height: 1.4),
            ),
            const SizedBox(height: 16),
            // Wrap, а не Row в цикле: у Row с растяжением по высоте внутри
            // ListView высота не ограничена, и строки схлопывались — на
            // экране оставалась только последняя пара карточек.
            Wrap(
              spacing: PtMetrics.gap,
              runSpacing: PtMetrics.gap,
              children: [
                for (final block in blocks)
                  SizedBox(
                    width: columns == 1
                        ? constraints.maxWidth - PtMetrics.pagePadding * 2
                        : (constraints.maxWidth -
                                PtMetrics.pagePadding * 2 -
                                PtMetrics.gap) /
                            2,
                    child: _buildBlockCard(block),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildBlockCard(OrderFormBlock block) {
    final active = block.canHide ? _isVisible(block.code) : true;
    final required = _isRequired(block.code);
    final hint = orderFormBlockHint(block.code, block.affectsStageQueue);

    return InkWell(
      // У неотключаемого блока нажатие по карточке переключает не видимость,
      // а требование: другого действия у неё нет.
      onTap: _canEdit
          ? () => block.canHide
              ? _toggleBlock(block, !active)
              : _toggleRequired(block, !required)
          : null,
      borderRadius: BorderRadius.circular(PtMetrics.cardRadius),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: active ? PtColors.cardActive : PtColors.cardIdle,
          borderRadius: BorderRadius.circular(PtMetrics.cardRadius),
          border: Border.all(
            color: active ? PtColors.primaryBorder : PtColors.border,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: block.canHide
                  ? PtToggle(
                      value: active,
                      onChanged: _canEdit
                          ? (value) => _toggleBlock(block, value)
                          : null,
                    )
                  // Блок, без которого форма не работает: выключателя нет,
                  // но потребовать его заполнение техлид всё равно может.
                  : const SizedBox(
                      width: 36,
                      height: 20,
                      child: Icon(Icons.lock_outline,
                          size: 14, color: PtColors.muted),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    block.title,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      color:
                          active ? PtColors.primaryText : PtColors.textSoft,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.35,
                      color: active ? PtColors.primaryMuted : PtColors.muted,
                    ),
                  ),
                  // Требование к скрытому блоку бессмысленно: заполнять
                  // нечего. Поэтому галочка гаснет вместе с блоком.
                  if (active) ...[
                    const SizedBox(height: 6),
                    _buildRequiredRow(block, required),
                    // Условие показывается только у отмеченного блока: без
                    // требования оно ничего не значит и было бы шумом.
                    if (required && _conditionsAvailable)
                      _buildConditionRow(block),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Строка условия: «обязателен всегда» или «обязателен, если …».
  Widget _buildConditionRow(OrderFormBlock block) {
    final condition = _conditions[block.code];
    final label = condition == null
        ? 'всегда'
        : blockConditionLabel(
            predicate: condition.predicate,
            negate: condition.negate,
            param: condition.param,
          );

    return Padding(
      padding: const EdgeInsets.only(left: 26, top: 2),
      child: InkWell(
        onTap: _canEdit ? () => _editCondition(block) : null,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.rule_folder_outlined,
                  size: 13, color: PtColors.mutedStrong),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  condition == null ? 'при условии: всегда' : 'если: $label',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: PtColors.mutedStrong,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Галочка «Обязателен» с расшифровкой последствия.
  Widget _buildRequiredRow(OrderFormBlock block, bool required) {
    return InkWell(
      onTap: _canEdit ? () => _toggleRequired(block, !required) : null,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: Checkbox(
                value: required,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: _canEdit
                    ? (value) => _toggleRequired(block, value == true)
                    : null,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              required
                  ? 'Обязателен — без него заказ останется черновиком'
                  : 'Обязателен',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: required ? FontWeight.w600 : FontWeight.w400,
                color: required ? PtColors.violetText : PtColors.mutedStrong,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
