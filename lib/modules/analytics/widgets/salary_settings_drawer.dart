import 'package:flutter/material.dart';

import '../../personnel/employee_status_model.dart';
import '../../personnel/personnel_provider.dart';
import '../../personnel/workplace_model.dart';
import '../models/salary_settings.dart';
import '../services/analytics_service.dart';
import '../utils/analytics_colors.dart';
import '../utils/format_utils.dart';

class SalarySettingsDrawer extends StatefulWidget {
  const SalarySettingsDrawer({
    super.key,
    required this.service,
    required this.personnel,
    required this.canEdit,
  });

  final AnalyticsService service;
  final PersonnelProvider personnel;
  final bool canEdit;

  @override
  State<SalarySettingsDrawer> createState() => _SalarySettingsDrawerState();
}

class _SalarySettingsDrawerState extends State<SalarySettingsDrawer> {
  late TextEditingController _nightCtrl;
  late TextEditingController _mealCtrl;
  late TextEditingController _socialCtrl;
  final Map<String, TextEditingController> _coeffCtrls = {};
  final Map<String, TextEditingController> _helperCtrls = {};
  final Map<String, TextEditingController> _statusRateCtrls = {};
  final Map<String, TextEditingController> _setupPriceCtrls = {};

  @override
  void initState() {
    super.initState();
    final s = widget.service.state.settings;
    _nightCtrl =
        TextEditingController(text: AnalyticsFormat.decimal(s.nightPercent));
    _mealCtrl =
        TextEditingController(text: AnalyticsFormat.decimal(s.mealAmount));
    _socialCtrl =
        TextEditingController(text: AnalyticsFormat.decimal(s.socialDefault));
  }

  @override
  void dispose() {
    _nightCtrl.dispose();
    _mealCtrl.dispose();
    _socialCtrl.dispose();
    for (final c in _coeffCtrls.values) {
      c.dispose();
    }
    for (final c in _helperCtrls.values) {
      c.dispose();
    }
    for (final c in _statusRateCtrls.values) {
      c.dispose();
    }
    for (final c in _setupPriceCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  double _parse(String s) {
    final n = s.replaceAll(',', '.').trim();
    return double.tryParse(n) ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final coeffs = widget.service.state.coefficients;
    final workplaces = widget.personnel.workplaces;
    final statuses = widget.service.state.statuses;
    final statusRates = widget.service.state.statusPayRates;

    return Drawer(
      backgroundColor: AnalyticsColors.bg2,
      width: 1000,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: ListView(
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Настройки оплаты',
                      style: TextStyle(
                        color: AnalyticsColors.text,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: AnalyticsColors.text),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                widget.canEdit
                    ? 'Ночные смены, питание, соц. отчисления и коэффициенты рабочих мест.'
                    : 'Просмотр настроек оплаты. Изменения доступны только техническому лидеру.',
                style:
                    const TextStyle(color: AnalyticsColors.muted, fontSize: 12),
              ),
              const SizedBox(height: 16),
              _section(
                'Ночные смены',
                'Процент от средней суммы за смену',
                _moneyField(
                  _nightCtrl,
                  suffix: '%',
                  enabled: widget.canEdit,
                  onChanged: widget.canEdit ? _scheduleSave : null,
                ),
              ),
              const SizedBox(height: 12),
              _section(
                'Питание',
                'Стоимость порции — удерживается за каждую смену',
                _moneyField(
                  _mealCtrl,
                  suffix: '₸',
                  enabled: widget.canEdit,
                  onChanged: widget.canEdit ? _scheduleSave : null,
                ),
              ),
              const SizedBox(height: 12),
              _section(
                'Соц. отчисления (по умолчанию)',
                'Используется как стартовое значение для нового месяца',
                _moneyField(
                  _socialCtrl,
                  suffix: '₸',
                  enabled: widget.canEdit,
                  onChanged: widget.canEdit ? _scheduleSave : null,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _coefficientsColumn(coeffs, workplaces)),
                  const SizedBox(width: 24),
                  Expanded(child: _setupPricesColumn(workplaces)),
                  const SizedBox(width: 24),
                  Expanded(child: _statusRatesColumn(statusRates, statuses)),
                ],
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _coefficientsColumn(
      Map<String, double> coeffs, List<WorkplaceModel> workplaces) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Коэффициенты рабочих мест',
          style: TextStyle(
            color: AnalyticsColors.text,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Сдельная оплата = количество × коэффициент. Если коэффициент 0 — '
          'рабочее место не учитывается в сдельной зарплате.\n'
          'На местах с совместной работой «помощник» — скидка к основному '
          'коэффициенту в процентах: -20 значит, что помощник получает 80% '
          'от ставки того, кто начал этап. 0 — поровну.',
          style: TextStyle(color: AnalyticsColors.muted, fontSize: 11),
        ),
        const SizedBox(height: 8),
        ...workplaces.map((w) {
          final ctrl = _coeffCtrls.putIfAbsent(
            w.id,
            () => TextEditingController(
              text: AnalyticsFormat.decimal(coeffs[w.id] ?? 0),
            ),
          );
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        w.name,
                        style: const TextStyle(
                          color: AnalyticsColors.text,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        'единица: ${w.unit ?? 'шт'}',
                        style: const TextStyle(
                          color: AnalyticsColors.muted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: ctrl,
                    enabled: widget.canEdit,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        color: AnalyticsColors.text,
                        fontWeight: FontWeight.w500),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      labelText: 'основной',
                    ),
                    onChanged: widget.canEdit
                        ? (v) {
                            widget.service.setWorkplaceCoefficient(
                              workplaceId: w.id,
                              coefficient: _parse(v),
                            );
                          }
                        : null,
                  ),
                ),
                // Ставка помощника есть только там, где вообще бывает
                // совместная работа: на «отдельном исполнителе» помощников
                // не существует, и поле только путало бы.
                if (w.executionMode == WorkplaceExecutionMode.joint) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 96,
                    child: TextField(
                      controller: _helperCtrls.putIfAbsent(
                        w.id,
                        () {
                          // Пустое поле = «как у основного». Показывать здесь
                          // ноль нельзя: ноль — это «помощнику не платим».
                          final rate =
                              widget.service.state.helperCoefficients[w.id];
                          return TextEditingController(
                            text: rate == null
                                ? ''
                                : AnalyticsFormat.decimal(rate),
                          );
                        },
                      ),
                      enabled: widget.canEdit,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          color: AnalyticsColors.text,
                          fontWeight: FontWeight.w500),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        labelText: 'помощник',
                        hintText: 'как основной',
                      ),
                      onChanged: widget.canEdit
                          ? (v) {
                              widget.service.setWorkplaceHelperCoefficient(
                                workplaceId: w.id,
                                helperCoefficient:
                                    v.trim().isEmpty ? null : _parse(v),
                              );
                            }
                          : null,
                    ),
                  ),
                ],
              ],
            ),
          );
        }),
      ],
    );
  }

  /// Колонка «Оплата приладки»: только рабочие места с включённой приладкой
  /// (hasMachine). Цена за одну засчитанную приладку; итог в ЗП =
  /// количество приладок × цена.
  Widget _setupPricesColumn(List<WorkplaceModel> workplaces) {
    final withSetup = workplaces.where((w) => w.hasMachine).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Оплата приладки',
          style: TextStyle(
            color: AnalyticsColors.text,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Цена за одну засчитанную приладку. Оплата = количество приладок × цена. Показаны только рабочие места с включённой приладкой.',
          style: TextStyle(color: AnalyticsColors.muted, fontSize: 11),
        ),
        const SizedBox(height: 8),
        if (withSetup.isEmpty)
          const Text(
            'Нет рабочих мест с включённой приладкой (Персонал → Рабочие места).',
            style: TextStyle(color: AnalyticsColors.muted, fontSize: 12),
          ),
        ...withSetup.map((w) {
          final ctrl = _setupPriceCtrls.putIfAbsent(
            w.id,
            () => TextEditingController(
              text: AnalyticsFormat.decimal(w.priladkaPrice),
            ),
          );
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        w.name,
                        style: const TextStyle(
                          color: AnalyticsColors.text,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        w.priladkaCalcMode == null
                            ? '₸/приладка · способ не выбран!'
                            : '₸/приладка · ${w.priladkaCalcMode!.label.toLowerCase()}',
                        style: TextStyle(
                          color: w.priladkaCalcMode == null
                              ? AnalyticsColors.red
                              : AnalyticsColors.muted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: ctrl,
                    enabled: widget.canEdit,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        color: AnalyticsColors.text,
                        fontWeight: FontWeight.w500),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: widget.canEdit
                        ? (v) {
                            widget.service.setWorkplaceSetupPrice(
                              workplaceId: w.id,
                              price: _parse(v),
                            );
                          }
                        : null,
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _statusRatesColumn(
      Map<String, double> statusRates, List<EmployeeStatus> statuses) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Оплата по статусам',
          style: TextStyle(
            color: AnalyticsColors.text,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Фиксированная ставка за смену вместо сдельной оплаты в дни действия статуса. Если ставка 0 или не задана — статус не влияет на оплату.',
          style: TextStyle(color: AnalyticsColors.muted, fontSize: 11),
        ),
        const SizedBox(height: 8),
        if (statuses.isEmpty)
          const Text(
            'Статусы ещё не созданы (Персонал → Статусы).',
            style: TextStyle(color: AnalyticsColors.muted, fontSize: 12),
          ),
        ...statuses.map((s) {
          final ctrl = _statusRateCtrls.putIfAbsent(
            s.id,
            () => TextEditingController(
              text: AnalyticsFormat.decimal(statusRates[s.id] ?? 0),
            ),
          );
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.name,
                        style: const TextStyle(
                          color: AnalyticsColors.text,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const Text(
                        '₸/смена',
                        style: TextStyle(
                          color: AnalyticsColors.muted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: ctrl,
                    enabled: widget.canEdit,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        color: AnalyticsColors.text,
                        fontWeight: FontWeight.w500),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: widget.canEdit
                        ? (v) {
                            widget.service.setStatusPayRate(
                              statusId: s.id,
                              fixedDayPay: _parse(v),
                            );
                          }
                        : null,
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _section(String title, String subtitle, Widget input) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AnalyticsColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AnalyticsColors.line),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                      color: AnalyticsColors.text,
                      fontWeight: FontWeight.w500,
                    )),
                Text(subtitle,
                    style: const TextStyle(
                      color: AnalyticsColors.muted,
                      fontSize: 11,
                    )),
              ],
            ),
          ),
          SizedBox(width: 140, child: input),
        ],
      ),
    );
  }

  Widget _moneyField(TextEditingController c,
      {required String suffix,
      required bool enabled,
      void Function(String)? onChanged}) {
    return TextField(
      controller: c,
      enabled: enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      textAlign: TextAlign.right,
      style: const TextStyle(
          color: AnalyticsColors.text, fontWeight: FontWeight.w500),
      decoration: InputDecoration(
        isDense: true,
        suffixText: suffix,
        border: const OutlineInputBorder(),
      ),
      onChanged: onChanged,
    );
  }

  void _scheduleSave(String _) {
    final settings = SalarySettings(
      effectiveMonth: widget.service.state.month.firstDay,
      nightPercent: _parse(_nightCtrl.text),
      mealAmount: _parse(_mealCtrl.text),
      socialDefault: _parse(_socialCtrl.text),
    );
    widget.service.saveSalarySettings(
      nightPercent: settings.nightPercent,
      mealAmount: settings.mealAmount,
      socialDefault: settings.socialDefault,
    );
  }
}
