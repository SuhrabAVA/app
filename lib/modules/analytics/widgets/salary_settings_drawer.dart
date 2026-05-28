import 'package:flutter/material.dart';

import '../../personnel/personnel_provider.dart';
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

  @override
  void initState() {
    super.initState();
    final s = widget.service.state.settings;
    _nightCtrl = TextEditingController(text: AnalyticsFormat.decimal(s.nightPercent));
    _mealCtrl = TextEditingController(text: AnalyticsFormat.decimal(s.mealAmount));
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

    return Drawer(
      backgroundColor: AnalyticsColors.bg2,
      width: 720,
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
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close,
                        color: AnalyticsColors.text),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                widget.canEdit
                    ? 'Ночные смены, питание, соц. отчисления и коэффициенты рабочих мест.'
                    : 'Просмотр настроек оплаты. Изменения доступны только техническому лидеру.',
                style: const TextStyle(
                    color: AnalyticsColors.muted, fontSize: 12),
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
              const Text(
                'Коэффициенты рабочих мест',
                style: TextStyle(
                  color: AnalyticsColors.text,
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Сдельная оплата = количество × коэффициент. Если коэффициент 0 — рабочее место не учитывается в сдельной зарплате.',
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
                                fontWeight: FontWeight.w800,
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
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                              color: AnalyticsColors.text,
                              fontWeight: FontWeight.w800),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
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
                    ],
                  ),
                );
              }),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
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
                      fontWeight: FontWeight.w800,
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
          color: AnalyticsColors.text, fontWeight: FontWeight.w900),
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
