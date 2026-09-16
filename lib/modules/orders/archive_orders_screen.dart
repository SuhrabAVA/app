import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'orders_provider.dart';
import 'material_model.dart';
import 'order_form_design.dart';
import 'order_model.dart';
import 'product_model.dart';
import 'edit_order_screen.dart';
import 'id_format.dart';
import 'shipment_summary.dart';
import '../../utils/kostanay_time.dart';
import 'view_order_screen.dart';

/// Экран архива заказов: завершённые заказы одной таблицей.
///
/// Переключателя «карточки/таблица» здесь нет намеренно. Архив читают, чтобы
/// СРАВНИТЬ заказы между собой — кто, когда и сколько отгрузил, что осталось
/// на складе, — а карточки такое сравнение разваливают: одни и те же поля
/// оказываются на разной высоте в каждой плитке. Поэтому вид один, а
/// сведения об отгрузке показываются целиком, без многоточий.
///
/// Из архива заказ возобновляют — открывается форма создания нового заказа с
/// заполненными данными, но некоторые поля обнуляются.
class ArchiveOrdersScreen extends StatefulWidget {
  const ArchiveOrdersScreen({super.key});
  @override
  State<ArchiveOrdersScreen> createState() => _ArchiveOrdersScreenState();
}

class _ArchiveOrdersScreenState extends State<ArchiveOrdersScreen> {
  final TextEditingController _searchController = TextEditingController();

  /// Отобранные менеджеры и типы продукта. Пустой список — «все».
  List<String> _filterManagers = <String>[];
  List<String> _filterProducts = <String>[];

  /// По какой дате фильтруем период. По умолчанию — дата создания: она есть у
  /// КАЖДОГО заказа, тогда как завершение и отгрузка бывают не проставлены, и
  /// выбранный период молча прятал бы половину архива.
  ArchiveDateBasis _dateBasis = ArchiveDateBasis.created;
  DateTimeRange? _dateRange;

  bool get _filterActive =>
      _filterManagers.isNotEmpty ||
      _filterProducts.isNotEmpty ||
      _dateRange != null;

  int get _filterCount =>
      _filterManagers.length + _filterProducts.length + (_dateRange == null ? 0 : 1);

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Завершённые заказы — то, из чего вообще состоит архив.
  ///
  /// Списки для фильтров строятся отсюда же, а не из всех заказов провайдера:
  /// менеджер, у которого в архиве ничего нет, в выпадающем списке даёт
  /// заведомо пустой результат.
  List<OrderModel> _archived(List<OrderModel> orders) =>
      orders.where((o) => o.statusEnum == OrderStatus.completed).toList();

  List<OrderModel> _filtered(List<OrderModel> orders) {
    final query = _searchController.text.trim().toLowerCase();
    final range = _dateRange;
    final result = _archived(orders).where((o) {
      if (_filterManagers.isNotEmpty &&
          !_filterManagers.contains(o.manager.trim())) {
        return false;
      }
      if (_filterProducts.isNotEmpty &&
          !_filterProducts.contains(o.product.type.trim())) {
        return false;
      }
      if (range != null &&
          !archiveOrderInRange(o, _dateBasis, range.start, range.end)) {
        return false;
      }
      if (query.isEmpty) return true;
      final displayId = orderDisplayId(o).toLowerCase();
      return o.customer.toLowerCase().contains(query) ||
          o.id.toLowerCase().contains(query) ||
          displayId.contains(query) ||
          o.product.type.toLowerCase().contains(query) ||
          o.manager.toLowerCase().contains(query);
    }).toList();
    // Свежие сверху: архив листают от последних отгрузок.
    result.sort((a, b) {
      final left = a.shippedAt ?? a.orderDate;
      final right = b.shippedAt ?? b.orderDate;
      return right.compareTo(left);
    });
    return result;
  }

  /// Значения для выпадающего фильтра: пустые строки в список не выносим —
  /// выбрать «никого» смысла нет.
  List<String> _distinct(
    List<OrderModel> orders,
    String Function(OrderModel) field,
  ) {
    final values = orders
        .map((o) => field(o).trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return values;
  }

  void _resumeOrder(BuildContext context, OrderModel order) {
    final p = order.product;
    final template = OrderModel(
      id: order.id,
      manager: order.manager,
      customer: order.customer,
      orderDate: DateTime.now(),
      dueDate: order.dueDate,
      product: ProductModel(
        id: p.id,
        type: p.type,
        quantity: p.quantity,
        width: p.width,
        height: p.height,
        depth: p.depth,
        parameters: p.parameters,
        roll: null,
        widthB: null,
        blQuantity: null,
        length: null,
        leftover: p.leftover,
      ),
      additionalParams: List<String>.from(order.additionalParams),
      handle: order.handle,
      cardboard: order.cardboard,
      material: order.material,
      // Полный список бумаг: без него многобумажный заказ при возобновлении
      // сводился бы к одной бумаге (fallback конструктора по material).
      paperMaterials: List<MaterialModel>.from(order.paperMaterials),
      makeready: order.makeready,
      val: order.val,
      pdfUrl: order.pdfUrl,
      stageTemplateId: null, // очередь очищаем
      // Привязка формы переживает возобновление — реквизиты переносятся
      // в новый заказ (EditOrderScreen сидирует ими своё состояние).
      hasForm: order.hasForm,
      isOldForm: order.isOldForm,
      newFormNo: order.newFormNo,
      formSeries: order.formSeries,
      formCode: order.formCode,
      contractSigned: order.contractSigned,
      paymentDone: order.paymentDone,
      comments: '',
      restartedFromOrderId: order.id,
      restartRootOrderId: order.restartRootOrderId ?? order.id,
      restartGeneration: order.restartGeneration + 1,
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditOrderScreen(initialOrder: template),
      ),
    );
  }

  /// Дата и время отгрузки в местном времени.
  ///
  /// База хранит UTC, показывать её как есть нельзя: устройство в цехе живёт
  /// по Костанаю, и разница читалась бы как «отгрузили на час раньше».
  String _shipmentDate(DateTime value) {
    final local = toKostanayTime(value);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}.${local.year} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OrderFormColors.background,
      body: SafeArea(
        child: Consumer<OrdersProvider>(
          builder: (context, provider, child) {
            final archived = _archived(provider.orders);
            final orders = _filtered(provider.orders);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(orders.length),
                _buildToolbar(archived),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    child: _buildTable(orders),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(int count) {
    // Стрелка «назад» появляется только там, где есть куда возвращаться:
    // архив открывают и отдельным экраном, и вкладкой рабочего места
    // менеджера, где кнопка вела бы в никуда.
    final canPop = Navigator.of(context).canPop();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 16, 8),
      child: Row(
        children: [
          if (canPop)
            IconButton(
              icon: const Icon(Icons.chevron_left, size: 26),
              color: OrderFormColors.muted,
              tooltip: 'Назад',
              onPressed: () => Navigator.of(context).pop(),
            )
          else
            const SizedBox(width: 4),
          const SizedBox(width: 4),
          const Text(
            'Архив заказов',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: OrderFormColors.text,
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFFE9EAEF),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '$count',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: OrderFormColors.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(List<OrderModel> archived) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              decoration: orderFieldDecoration(
                hintText: 'Поиск по номеру, заказчику, продукту…',
                prefixIcon: const Icon(Icons.search,
                    size: 18, color: OrderFormColors.label),
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 10),
          // Один компактный вход в фильтры вместо выпадающих списков в строку:
          // списки менеджеров и типов продукта раздували шапку на треть
          // экрана, а нужны они раз в сеанс.
          OutlinedButton.icon(
            onPressed: () => _openFilter(archived),
            style: _controlStyle(active: _filterActive),
            icon: const Icon(Icons.filter_list, size: 16),
            label: Text(_filterActive ? 'Фильтр · $_filterCount' : 'Фильтр'),
          ),
          if (_filterActive) ...[
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: () => setState(() {
                _filterManagers = <String>[];
                _filterProducts = <String>[];
                _dateRange = null;
              }),
              icon: const Icon(Icons.close, size: 16),
              label: const Text('Сбросить'),
              style: TextButton.styleFrom(
                foregroundColor: OrderFormColors.muted,
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Кнопки-управления в шапке: та же высота и радиус, что у поиска.
  static ButtonStyle _controlStyle({required bool active}) =>
      OutlinedButton.styleFrom(
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        foregroundColor:
            active ? OrderFormColors.accent : OrderFormColors.muted,
        backgroundColor:
            active ? OrderFormColors.accentSoft : OrderFormColors.fieldFill,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        side: BorderSide(
          color: active ? OrderFormColors.accentBorder : OrderFormColors.border,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OrderFormMetrics.fieldRadius),
        ),
      );

  /// Окно фильтра: менеджеры, типы продукта и период по выбранной дате.
  ///
  /// Значения чипов берутся из [archived] — уже завершённых заказов: менеджер,
  /// у которого в архиве ничего нет, дал бы заведомо пустой результат.
  /// Правки копятся локально и применяются кнопкой: иначе список под окном
  /// перестраивался бы на каждый тап.
  void _openFilter(List<OrderModel> archived) {
    final managers = _distinct(archived, (o) => o.manager);
    final products = _distinct(archived, (o) => o.product.type);
    final selectedManagers = List<String>.from(_filterManagers);
    final selectedProducts = List<String>.from(_filterProducts);
    var selectedBasis = _dateBasis;
    DateTimeRange? selectedRange = _dateRange;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: OrderFormColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            Widget sectionTitle(String text) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    text,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: OrderFormColors.text,
                    ),
                  ),
                );

            Widget chips(
              List<String> values,
              List<String> selection,
              String emptyHint,
            ) {
              if (values.isEmpty) {
                return Text(
                  emptyHint,
                  style: const TextStyle(
                      fontSize: 12, color: OrderFormColors.muted),
                );
              }
              return Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final value in values)
                    FilterChip(
                      label: Text(value, style: const TextStyle(fontSize: 12)),
                      selected: selection.contains(value),
                      showCheckmark: false,
                      backgroundColor: OrderFormColors.fieldFill,
                      selectedColor: OrderFormColors.accentSoft,
                      side: BorderSide(
                        color: selection.contains(value)
                            ? OrderFormColors.accentBorder
                            : OrderFormColors.border,
                      ),
                      labelStyle: TextStyle(
                        color: selection.contains(value)
                            ? OrderFormColors.accent
                            : OrderFormColors.text,
                        fontWeight: selection.contains(value)
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                      onSelected: (picked) => setSheetState(() {
                        if (picked) {
                          selection.add(value);
                        } else {
                          selection.remove(value);
                        }
                      }),
                    ),
                ],
              );
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 18,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Фильтр',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: OrderFormColors.text,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 20),
                          color: OrderFormColors.muted,
                          onPressed: () => Navigator.pop(sheetContext),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    sectionTitle('Менеджеры'),
                    chips(managers, selectedManagers,
                        'В архиве нет заказов с менеджером'),
                    const SizedBox(height: 16),
                    sectionTitle('Типы продукта'),
                    chips(products, selectedProducts,
                        'В архиве нет типов продукта'),
                    const SizedBox(height: 16),
                    sectionTitle('Период'),
                    // Основание периода выбирается явно: три даты архивного
                    // заказа расходятся на недели, и «дата создания» не
                    // отвечает на вопрос «что отгрузили в сентябре».
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final basis in ArchiveDateBasis.values)
                          ChoiceChip(
                            label: Text(
                              archiveDateBasisLabel(basis),
                              style: const TextStyle(fontSize: 12),
                            ),
                            selected: selectedBasis == basis,
                            showCheckmark: false,
                            backgroundColor: OrderFormColors.fieldFill,
                            selectedColor: OrderFormColors.accentSoft,
                            side: BorderSide(
                              color: selectedBasis == basis
                                  ? OrderFormColors.accentBorder
                                  : OrderFormColors.border,
                            ),
                            labelStyle: TextStyle(
                              color: selectedBasis == basis
                                  ? OrderFormColors.accent
                                  : OrderFormColors.text,
                              fontWeight: selectedBasis == basis
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                            onSelected: (_) =>
                                setSheetState(() => selectedBasis = basis),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            style: _controlStyle(active: selectedRange != null),
                            icon: const Icon(Icons.date_range, size: 16),
                            onPressed: () async {
                              final now = DateTime.now();
                              final picked = await showDateRangePicker(
                                context: sheetContext,
                                firstDate: DateTime(now.year - 5),
                                lastDate: DateTime(now.year + 5),
                                initialDateRange: selectedRange,
                              );
                              if (picked != null) {
                                setSheetState(() => selectedRange = picked);
                              }
                            },
                            label: Text(
                              selectedRange == null
                                  ? 'Выбрать период'
                                  : '${_formatDay(selectedRange!.start)} — '
                                      '${_formatDay(selectedRange!.end)}',
                            ),
                          ),
                        ),
                        if (selectedRange != null)
                          IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            color: OrderFormColors.muted,
                            tooltip: 'Убрать период',
                            onPressed: () =>
                                setSheetState(() => selectedRange = null),
                          ),
                      ],
                    ),
                    if (selectedRange != null &&
                        selectedBasis != ArchiveDateBasis.created) ...[
                      const SizedBox(height: 6),
                      // Честно предупреждаем: заказ без выбранной даты в
                      // период не попадёт вовсе, и список станет короче не
                      // из-за периода, а из-за пустого поля.
                      const Text(
                        'Заказы без этой даты в период не попадут.',
                        style: TextStyle(
                            fontSize: 11, color: OrderFormColors.muted),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: () {
                        setState(() {
                          _filterManagers = selectedManagers;
                          _filterProducts = selectedProducts;
                          _dateBasis = selectedBasis;
                          _dateRange = selectedRange;
                        });
                        Navigator.pop(sheetContext);
                      },
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 42),
                        backgroundColor: OrderFormColors.accent,
                      ),
                      child: const Text('Применить'),
                    ),
                    const SizedBox(height: 6),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _filterManagers = <String>[];
                          _filterProducts = <String>[];
                          _dateBasis = ArchiveDateBasis.created;
                          _dateRange = null;
                        });
                        Navigator.pop(sheetContext);
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: OrderFormColors.muted,
                      ),
                      child: const Text('Сбросить'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Дата без времени — для подписи выбранного периода.
  static String _formatDay(DateTime value) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(value.day)}.${two(value.month)}.${value.year}';
  }

  Widget _buildTable(List<OrderModel> orders) {
    return Container(
      decoration: BoxDecoration(
        color: OrderFormColors.surface,
        borderRadius: BorderRadius.circular(OrderFormMetrics.cardRadius),
        border: Border.all(color: OrderFormColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Колонок семь, и сжимать их до нечитаемости нельзя — на узком
          // экране таблица прокручивается вбок целиком.
          const double minWidth = 1180;
          final double width = constraints.maxWidth < minWidth
              ? minWidth
              : constraints.maxWidth;
          final table = SizedBox(
            width: width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildTableHeader(),
                Expanded(
                  child: orders.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Text(
                              'Ни одного заказа по этим условиям',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: OrderFormColors.muted),
                            ),
                          ),
                        )
                      : ListView.separated(
                          itemCount: orders.length,
                          separatorBuilder: (_, __) => const Divider(
                              height: 1, color: OrderFormColors.divider),
                          itemBuilder: (_, i) => _buildRow(orders[i]),
                        ),
                ),
              ],
            ),
          );
          if (constraints.maxWidth >= minWidth) return table;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: minWidth, child: table),
          );
        },
      ),
    );
  }

  // Ширины колонок держим в одном месте: шапка и строки обязаны совпадать до
  // пикселя, иначе «Заказчик» встанет над столбцом продукта.
  static const int _flexNumber = 22;
  static const int _flexCustomer = 22;
  static const int _flexProduct = 20;
  static const int _flexQty = 12;
  static const int _flexShipment = 32;
  static const int _flexStatus = 14;
  static const double _actionsWidth = 240;

  Widget _buildTableHeader() {
    Widget cell(String label, int flex, {Alignment align = Alignment.centerLeft}) =>
        Expanded(
          flex: flex,
          child: Align(
            alignment: align,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.9,
                color: OrderFormColors.muted,
              ),
            ),
          ),
        );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xFFF7F8FB),
        border: Border(
          bottom: BorderSide(color: OrderFormColors.border),
        ),
      ),
      child: Row(
        children: [
          cell('НОМЕР', _flexNumber),
          cell('ЗАКАЗЧИК', _flexCustomer),
          cell('ПРОДУКТ', _flexProduct),
          cell('ТИРАЖ', _flexQty, align: Alignment.centerRight),
          const SizedBox(width: 12),
          cell('ОТГРУЗКА', _flexShipment),
          cell('СТАТУС', _flexStatus),
          const SizedBox(width: _actionsWidth),
        ],
      ),
    );
  }

  Widget _buildRow(OrderModel order) {
    final displayId = orderDisplayId(order);
    final orderNumber = displayId == '—' ? order.id : displayId;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: _flexNumber,
            child: Text(
              orderNumber,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
                color: OrderFormColors.muted,
              ),
            ),
          ),
          Expanded(
            flex: _flexCustomer,
            child: Text(
              order.customer.trim().isEmpty ? '—' : order.customer,
              maxLines: 2,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: OrderFormColors.text,
              ),
            ),
          ),
          Expanded(
            flex: _flexProduct,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _ProductBadge(type: order.product.type),
            ),
          ),
          Expanded(
            flex: _flexQty,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                _thousands(order.product.quantity),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                  color: OrderFormColors.text,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: _flexShipment,
            child: _buildShipmentCell(order),
          ),
          Expanded(
            flex: _flexStatus,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _ShipmentBadge(state: archiveShipmentStateOf(order)),
            ),
          ),
          SizedBox(
            width: _actionsWidth,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) =>
                        ViewOrderDialog(order: order, showHistoryFirst: true),
                  ),
                  icon: const Icon(Icons.history, size: 16),
                  label: const Text('История'),
                  style: TextButton.styleFrom(
                    foregroundColor: OrderFormColors.muted,
                    textStyle: const TextStyle(fontSize: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _resumeOrder(context, order),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Возобновить'),
                  style: TextButton.styleFrom(
                    foregroundColor: OrderFormColors.accent,
                    textStyle: const TextStyle(fontSize: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Сведения об отгрузке целиком: когда, кто, сколько и что осталось.
  ///
  /// Ничего не обрезаем многоточием — ради этих четырёх чисел архив и
  /// открывают, а «Хибуллаева За…» не отвечает ни на один вопрос.
  Widget _buildShipmentCell(OrderModel order) {
    final shipment = shipmentSummaryOf(order);
    if (shipment == null) {
      final produced = order.actualQty ?? 0;
      return Text(
        produced > 0
            ? 'Не отгружен · произведено ${formatShipmentQty(produced)}'
            : '—',
        style: const TextStyle(fontSize: 12, color: OrderFormColors.muted),
      );
    }

    final deviation = formatShipmentDeviation(shipment.deviationFromPlan);
    final bool shippedLess = (shipment.deviationFromPlan ?? 0) < 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${_shipmentDate(shipment.shippedAt)} · '
          '${formatShippedBy(shipment.shippedBy)}',
          style: const TextStyle(fontSize: 12, color: OrderFormColors.text),
        ),
        const SizedBox(height: 2),
        Wrap(
          spacing: 8,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Отгружено ${formatShipmentQty(shipment.shippedQty)}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: OrderFormColors.text,
              ),
            ),
            if (deviation.isNotEmpty)
              Text(
                '$deviation к тиражу',
                style: TextStyle(
                  fontSize: 12,
                  color: shippedLess ? Colors.red : OrderFormColors.muted,
                ),
              ),
            if (shipment.hasRemainder)
              Text(
                'остаток ${formatShipmentQty(shipment.remainingQty)}',
                style: const TextStyle(
                    fontSize: 12, color: OrderFormColors.muted),
              ),
          ],
        ),
      ],
    );
  }

  /// Разряды пробелами: «10 495» читается с одного взгляда, «10495» — нет.
  static String _thousands(int value) {
    final digits = value.abs().toString();
    final buffer = StringBuffer(value < 0 ? '−' : '');
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }
}

/// Бейдж типа продукта. Цвет выводится из названия, а не настраивается:
/// типов продукта девять и они меняются в справочнике, а ручная палитра
/// пришлось бы догонять каждый новый тип белым пятном.
class _ProductBadge extends StatelessWidget {
  const _ProductBadge({required this.type});

  final String type;

  static const List<List<Color>> _palette = <List<Color>>[
    [Color(0xFFEDE9FE), Color(0xFF6D28D9)],
    [Color(0xFFDBEAFE), Color(0xFF1D4ED8)],
    [Color(0xFFFFEDD5), Color(0xFFC2410C)],
    [Color(0xFFDCFCE7), Color(0xFF15803D)],
    [Color(0xFFFCE7F3), Color(0xFFBE185D)],
    [Color(0xFFCFFAFE), Color(0xFF0E7490)],
    [Color(0xFFFEF3C7), Color(0xFF92400E)],
  ];

  @override
  Widget build(BuildContext context) {
    final label = type.trim();
    if (label.isEmpty) {
      return const Text('—',
          style: TextStyle(fontSize: 12, color: OrderFormColors.muted));
    }
    var hash = 0;
    for (final unit in label.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    final colors = _palette[hash % _palette.length];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors[0],
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: colors[1],
        ),
      ),
    );
  }
}

/// Бейдж состояния отгрузки — три состояния из [archiveShipmentStateOf].
class _ShipmentBadge extends StatelessWidget {
  const _ShipmentBadge({required this.state});

  final ArchiveShipmentState state;

  @override
  Widget build(BuildContext context) {
    final Color background;
    final Color foreground;
    switch (state) {
      case ArchiveShipmentState.shipped:
        background = const Color(0xFFDCFCE7);
        foreground = const Color(0xFF15803D);
        break;
      case ArchiveShipmentState.inStock:
        background = const Color(0xFFF3F4F6);
        foreground = const Color(0xFF4B5563);
        break;
      case ArchiveShipmentState.notShipped:
        background = const Color(0xFFFEF3C7);
        foreground = const Color(0xFF92400E);
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: foreground, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            archiveShipmentLabel(state),
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}
