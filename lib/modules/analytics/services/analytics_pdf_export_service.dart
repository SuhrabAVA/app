import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../personnel/employee_model.dart';
import '../../personnel/personnel_provider.dart';
import '../../personnel/workplace_model.dart';
import '../calculators/analytics_calculator.dart';
import '../calculators/kpd_calculator.dart';
import '../calculators/rating_calculator.dart';
import '../calculators/salary_calculator.dart';
import '../models/analytics_event.dart';
import '../models/analytics_month.dart';
import '../models/day_shift_type.dart';
import '../models/pay_type.dart';
import '../models/salary_adjustments.dart';
import '../models/work_schedule_entry.dart';
import '../services/analytics_service.dart';
import '../utils/analytics_constants.dart';
import '../utils/format_utils.dart';

class AnalyticsPdfExportService {
  AnalyticsPdfExportService();

  pw.Font? _regularFont;
  pw.Font? _boldFont;

  Future<String?> exportEmployeesTablePdf({
    required AnalyticsService service,
    required PersonnelProvider personnel,
  }) async {
    final state = service.state;
    final rows = _buildEmployeeRows(service, personnel);
    final doc = await _createDocument();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(18),
        theme: _theme(),
        footer: _buildFooter,
        build: (context) => [
          _buildHeader('Аналитика сотрудников', state.month),
          if (rows.isEmpty) _emptyBlock(state.month) else ...[
            _buildTable(
              headers: const [
                'Сотрудник',
                'Статус',
                'Дни',
                'Ночи',
                'Рабочие места',
                'Сделано',
                'Приладка',
                'Паузы',
                'Проблемы',
                'Претензии',
                'Тип оплаты',
                'Средняя ЗП',
                'Ночные',
                'Компенсации',
                'Соц. отчисления',
                'Питание',
                'Аванс',
                'ЗП безнал',
                'Дисциплина',
                'Браки',
                'Итог ЗП',
                'Ведомость',
              ],
              data: rows.map((r) => r.tableCells).toList(),
              fontSize: 5.4,
            ),
            pw.SizedBox(height: 10),
            _buildKpiBlock(_employeeTotals(rows)),
          ],
        ],
      ),
    );

    return _savePdfFile(
      await doc.save(),
      _fileName('analytics_employees', state.month),
    );
  }

  Future<String?> exportEmployeeDetailPdf({
    required AnalyticsService service,
    required PersonnelProvider personnel,
    required String employeeId,
    int? selectedDay,
    String? workplaceFilter,
  }) async {
    final state = service.state;
    final employee = _employeeById(personnel, employeeId);
    if (employee == null) {
      return _saveSimplePdf(
        title: 'Детальная аналитика сотрудника',
        month: state.month,
        fileName: _fileName('analytics_employee_unknown', state.month),
        message: 'Сотрудник не найден.',
      );
    }

    final allEvents = state.events.where((e) => e.employeeId == employeeId).toList();
    final filter = workplaceFilter ?? AnalyticsConstants.allWorkplaces;
    final filteredEvents = filter == AnalyticsConstants.allWorkplaces
        ? allEvents
        : allEvents.where((e) => e.workplaceId == filter).toList();
    final eventsByDay = _eventsByDay(filteredEvents);
    final day = selectedDay ?? (eventsByDay.keys.isEmpty ? 1 : eventsByDay.keys.reduce((a, b) => a < b ? a : b));
    final dayEvents = eventsByDay[day] ?? const <AnalyticsEvent>[];
    final brk = _salaryForEmployee(service, employeeId, allEvents);
    final statusName = _statusName(service, employeeId);
    final claimsCount = state.claims.where((c) => c.employeeId == employeeId).length;
    final workplaceRows = _employeeWorkplaceRows(service, personnel, employeeId, allEvents);
    final calendarRows = List.generate(state.month.daysCount, (i) {
      final d = i + 1;
      final entry = state.schedules[employeeId]?[d];
      final list = eventsByDay[d] ?? const <AnalyticsEvent>[];
      final conflict = (entry?.shiftType ?? DayShiftType.off) == DayShiftType.off && list.isNotEmpty;
      return [
        _date(state.month, d),
        shiftTypeLabel(entry?.shiftType ?? DayShiftType.off),
        entry?.arrivalTime ?? '—',
        entry?.departureTime ?? '—',
        list.isEmpty ? 'нет' : 'да (${list.length})',
        conflict ? 'Конфликт' : '—',
      ];
    });

    final doc = await _createDocument();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        theme: _theme(),
        footer: _buildFooter,
        build: (context) => [
          _buildHeader('Детальная аналитика сотрудника', state.month),
          _buildKpiBlock({
            'Сотрудник': _employeeName(employee),
            'Статус': statusName,
            'Дни': '${brk.dayShifts}',
            'Ночи': '${brk.nightShifts}',
            'Рабочие места': '${workplaceRows.length}',
            'Сделано': AnalyticsFormat.decimal(AnalyticsCalculator.totalQty(allEvents)),
            'Полезное время': AnalyticsFormat.hoursMinutes(AnalyticsCalculator.usefulMinutes(allEvents)),
            'Паузы': '${AnalyticsCalculator.countEventsOfType(allEvents, AnalyticsEventType.pause)} / ${AnalyticsFormat.hoursMinutes(AnalyticsCalculator.pauseMinutes(allEvents))}',
            'Проблемы': '${AnalyticsCalculator.countEventsOfType(allEvents, AnalyticsEventType.problem)} / ${AnalyticsFormat.hoursMinutes(AnalyticsCalculator.problemMinutes(allEvents))}',
            'Претензии': '$claimsCount',
          }),
          _section('Рабочие места сотрудника'),
          _buildTable(
            headers: const ['Рабочее место', 'Сделано', 'Ед.', 'Полезное время', 'Скорость', 'Паузы', 'Проблемы', 'Претензии'],
            data: workplaceRows,
          ),
          _section('Календарь'),
          _buildTable(
            headers: const ['Дата', 'Тип смены', 'Приход', 'Уход', 'Активность', 'Конфликт'],
            data: calendarRows,
            fontSize: 8,
          ),
          _section('Выбранный день: ${_date(state.month, day)}'),
          _buildTable(
            headers: const ['Событие', 'Заказчик / рабочее место', 'Время', 'Длительность', 'Количество', 'Описание'],
            data: _eventRows(dayEvents, personnel),
            fontSize: 7,
          ),
          _section('Финансовый блок'),
          _salaryBlock(service, employeeId, brk),
        ],
      ),
    );

    return _savePdfFile(
      await doc.save(),
      _fileName('analytics_employee_${_safeName(_employeeName(employee))}', state.month),
    );
  }

  Future<String?> exportWorkplacesTablePdf({
    required AnalyticsService service,
    required PersonnelProvider personnel,
  }) async {
    final state = service.state;
    final rows = _buildWorkplaceRows(service, personnel);
    final doc = await _createDocument();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(18),
        theme: _theme(),
        footer: _buildFooter,
        build: (context) => [
          _buildHeader('Аналитика рабочих мест', state.month),
          if (rows.isEmpty) _emptyBlock(state.month) else ...[
            _buildTable(
              headers: const ['Рабочее место', 'Единица измерения', 'Коэффициент', 'Количество', 'Время', 'Средняя скорость', 'Наладки', 'Заказы', 'Паузы', 'Проблемы', 'Претензии', 'КПД'],
              data: rows.map((r) => r.tableCells).toList(),
              fontSize: 7,
            ),
            pw.SizedBox(height: 10),
            _buildKpiBlock(_workplaceTotals(rows)),
          ],
        ],
      ),
    );

    return _savePdfFile(
      await doc.save(),
      _fileName('analytics_workplaces', state.month),
    );
  }

  Future<String?> exportWorkplaceDetailPdf({
    required AnalyticsService service,
    required PersonnelProvider personnel,
    required String workplaceId,
    int? selectedDay,
  }) async {
    final state = service.state;
    final workplace = personnel.workplaceById(workplaceId);
    if (workplace == null) {
      return _saveSimplePdf(
        title: 'Детальная аналитика рабочего места',
        month: state.month,
        fileName: _fileName('analytics_workplace_unknown', state.month),
        message: 'Рабочее место не найдено.',
      );
    }

    final events = state.events.where((e) => e.workplaceId == workplaceId).toList();
    final unit = _unit(workplace);
    final eventsByDay = _eventsByDay(events);
    final day = selectedDay ?? (eventsByDay.keys.isEmpty ? 1 : eventsByDay.keys.reduce((a, b) => a < b ? a : b));
    final qty = AnalyticsCalculator.totalQty(events);
    final useful = AnalyticsCalculator.usefulMinutes(events);
    final speed = useful > 0 ? qty / useful : 0.0;
    final kpd = KpdCalculator.compute(
      currentSpeed: speed,
      previousMonthsSpeeds: state.workplacePreviousSpeeds[workplaceId] ?? const [],
    );
    final ratings = RatingCalculator.buildForWorkplace(eventsForWorkplace: events);

    final doc = await _createDocument();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        theme: _theme(),
        footer: _buildFooter,
        build: (context) => [
          _buildHeader('Детальная аналитика рабочего места', state.month),
          _buildKpiBlock({
            'Рабочее место': workplace.name,
            'Единица измерения': unit,
            'Коэффициент': AnalyticsFormat.decimal(state.coefficients[workplaceId] ?? 0),
            'Общее количество': '${AnalyticsFormat.decimal(qty)} $unit',
            'Полезное время': AnalyticsFormat.hoursMinutes(useful),
            'Средняя скорость': '${AnalyticsFormat.decimal(speed)} $unit/мин',
            'Наладки': '${AnalyticsFormat.decimal(AnalyticsCalculator.totalSetupQty(events))} / ${AnalyticsFormat.hoursMinutes(AnalyticsCalculator.setupMinutes(events))}',
            'Паузы': '${AnalyticsCalculator.countEventsOfType(events, AnalyticsEventType.pause)} / ${AnalyticsFormat.hoursMinutes(AnalyticsCalculator.pauseMinutes(events))}',
            'Проблемы': '${AnalyticsCalculator.countEventsOfType(events, AnalyticsEventType.problem)} / ${AnalyticsFormat.hoursMinutes(AnalyticsCalculator.problemMinutes(events))}',
            'Претензии': '${state.claims.where((c) => c.workplaceId == workplaceId).length}',
            'КПД': '${kpd.kpdPercent.round()}%',
          }),
          _section('Календарь активности'),
          _buildTable(
            headers: const ['Дата', 'Количество', 'Полезное время', 'Скорость', 'Паузы', 'Проблемы'],
            data: List.generate(state.month.daysCount, (i) {
              final d = i + 1;
              final list = eventsByDay[d] ?? const <AnalyticsEvent>[];
              final dayQty = AnalyticsCalculator.totalQty(list);
              final dayUseful = AnalyticsCalculator.usefulMinutes(list);
              return [
                _date(state.month, d),
                AnalyticsFormat.decimal(dayQty),
                AnalyticsFormat.hoursMinutes(dayUseful),
                '${AnalyticsFormat.decimal(dayUseful > 0 ? dayQty / dayUseful : 0)} $unit/мин',
                '${AnalyticsCalculator.countEventsOfType(list, AnalyticsEventType.pause)}',
                '${AnalyticsCalculator.countEventsOfType(list, AnalyticsEventType.problem)}',
              ];
            }),
            fontSize: 8,
          ),
          _section('Список заказов за выбранный день: ${_date(state.month, day)}'),
          _buildTable(
            headers: const ['Заказчик', 'Заказ', 'Сотрудник', 'Время', 'Длительность', 'Количество', 'Описание'],
            data: _eventRows(eventsByDay[day] ?? const <AnalyticsEvent>[], personnel, includeOrder: true),
            fontSize: 7,
          ),
          _section('Рейтинг сотрудников'),
          _buildTable(
            headers: const ['Место', 'Сотрудник', 'Количество', 'Полезное время', 'Скорость количество/мин', 'Количество смен'],
            data: List.generate(ratings.length, (i) {
              final r = ratings[i];
              final employee = _employeeById(personnel, r.employeeId);
              final brk = _salaryForEmployee(service, r.employeeId, events.where((e) => e.employeeId == r.employeeId).toList());
              return ['${i + 1}', employee == null ? r.employeeId : _employeeName(employee), AnalyticsFormat.decimal(r.qty), AnalyticsFormat.hoursMinutes(r.usefulMinutes), AnalyticsFormat.decimal(r.speed), '${brk.shiftsTotal}'];
            }),
          ),
        ],
      ),
    );

    return _savePdfFile(
      await doc.save(),
      _fileName('analytics_workplace_${_safeName(workplace.name)}', state.month),
    );
  }

  Future<String?> exportWorkSchedulePdf({
    required AnalyticsService service,
    required PersonnelProvider personnel,
  }) async {
    final state = service.state;
    final doc = await _createDocument();
    final employees = personnel.employees.where((e) => !e.isFired).toList()
      ..sort((a, b) => _employeeName(a).compareTo(_employeeName(b)));
    final activity = <String, Map<int, List<AnalyticsEvent>>>{};
    for (final e in state.events) {
      activity.putIfAbsent(e.employeeId, () => {}).putIfAbsent(e.startTime.day, () => []).add(e);
    }

    pw.Widget schedulePart(int from, int to) {
      final days = List.generate(to - from + 1, (i) => from + i);
      return _buildTable(
        headers: ['Сотрудник', 'Статус', ...days.map((d) => '$d')],
        data: employees.map((employee) {
          final byDay = state.schedules[employee.id] ?? const <int, WorkScheduleEntry>{};
          return [
            _employeeName(employee),
            _statusName(service, employee.id),
            ...days.map((d) {
              final entry = byDay[d];
              final list = activity[employee.id]?[d] ?? const <AnalyticsEvent>[];
              final shift = entry?.shiftType ?? DayShiftType.off;
              final conflict = shift == DayShiftType.off && list.isNotEmpty;
              return '${shiftTypeLabel(shift)}\n${entry?.arrivalTime ?? '—'}-${entry?.departureTime ?? '—'}${conflict ? '\n!' : ''}';
            }),
          ];
        }).toList(),
        fontSize: 5.8,
      );
    }

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(18),
        theme: _theme(),
        footer: _buildFooter,
        build: (context) => [
          _buildHeader('График работы сотрудников', state.month),
          if (employees.isEmpty) _emptyBlock(state.month) else ...[
            _section('Дни 1–15'),
            schedulePart(1, state.month.daysCount < 15 ? state.month.daysCount : 15),
            if (state.month.daysCount > 15) ...[
              _section('Дни 16–${state.month.daysCount}'),
              schedulePart(16, state.month.daysCount),
            ],
          ],
        ],
      ),
    );

    return _savePdfFile(
      await doc.save(),
      _fileName('analytics_schedule', state.month),
    );
  }

  Future<String?> exportSalaryStatementPdf({
    required AnalyticsService service,
    required PersonnelProvider personnel,
  }) async {
    final state = service.state;
    final rows = _buildEmployeeRows(service, personnel);
    final doc = await _createDocument();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(18),
        theme: _theme(),
        footer: _buildFooter,
        build: (context) => [
          _buildHeader('Зарплатная ведомость', state.month),
          _buildTable(
            headers: const ['Сотрудник', 'Статус', 'Тип оплаты', 'Дни', 'Ночи', 'Сделано', 'Сдельная сумма', 'Окладная сумма', 'Средняя ЗП', 'Ночные', 'Компенсации', 'Соц. отчисления', 'Питание', 'Аванс', 'ЗП безнал', 'Дисциплина', 'Браки', 'Итог ЗП'],
            data: rows.map((r) => r.salaryCells).toList(),
            fontSize: 6,
          ),
          pw.SizedBox(height: 10),
          _buildKpiBlock({
            'Общий итог начислений': AnalyticsFormat.money(rows.fold<double>(0, (s, r) => s + r.breakdown.accrued + r.breakdown.compensation)),
            'Общий итог удержаний': AnalyticsFormat.money(rows.fold<double>(0, (s, r) => s + r.breakdown.deductions)),
            'Общий итог к выплате': AnalyticsFormat.money(rows.fold<double>(0, (s, r) => s + r.breakdown.total)),
          }),
        ],
      ),
    );

    return _savePdfFile(await doc.save(), _fileName('analytics_salary', state.month));
  }

  Future<void> openPdfFile(String path) async {
    await OpenFilex.open(path);
  }

  Future<pw.Document> _createDocument() async {
    await _ensureFonts();
    return pw.Document();
  }

  Future<void> _ensureFonts() async {
    if (_regularFont != null) return;
    Future<pw.Font?> tryFont(String path) async {
      try {
        final file = File(path);
        if (!await file.exists()) return null;
        return pw.Font.ttf(await file.readAsBytes().then(ByteData.sublistView));
      } catch (_) {
        return null;
      }
    }

    _regularFont = await tryFont('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf') ??
        await tryFont('/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf') ??
        await tryFont(r'C:\Windows\Fonts\arial.ttf') ??
        await tryFont('/System/Library/Fonts/Supplemental/Arial.ttf');
    _boldFont = await tryFont('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf') ??
        await tryFont('/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf') ??
        await tryFont(r'C:\Windows\Fonts\arialbd.ttf') ??
        await tryFont('/System/Library/Fonts/Supplemental/Arial Bold.ttf') ??
        _regularFont;
  }

  pw.ThemeData _theme() {
    final base = pw.ThemeData.base();
    if (_regularFont == null) return base;
    return pw.ThemeData.withFont(base: _regularFont, bold: _boldFont ?? _regularFont);
  }

  pw.Widget _buildHeader(String title, AnalyticsMonth month) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(title, style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.Text('Месяц: ${_monthText(month)}', style: const pw.TextStyle(fontSize: 11)),
        pw.Text('Дата формирования: ${_dateTime(DateTime.now())}', style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
        pw.SizedBox(height: 12),
      ],
    );
  }

  pw.Widget _buildFooter(pw.Context context) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('Стр. ${context.pageNumber} / ${context.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
      );

  pw.Widget _section(String title) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 14, bottom: 6),
        child: pw.Text(title, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
      );

  pw.Widget _buildTable({required List<String> headers, required List<List<String>> data, double fontSize = 7}) {
    final safeData = data.isEmpty ? [List.filled(headers.length, 'Нет данных за выбранный месяц')] : data;
    return pw.Table.fromTextArray(
      headers: headers,
      data: safeData,
      headerStyle: pw.TextStyle(fontSize: fontSize, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
      headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey900),
      cellStyle: pw.TextStyle(fontSize: fontSize),
      cellAlignment: pw.Alignment.centerLeft,
      headerAlignment: pw.Alignment.centerLeft,
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 3),
      border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.3),
      oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
    );
  }

  pw.Widget _buildKpiBlock(Map<String, String> values) => pw.Wrap(
        spacing: 6,
        runSpacing: 6,
        children: values.entries.map((e) => pw.Container(
          width: 150,
          padding: const pw.EdgeInsets.all(7),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400, width: 0.4), borderRadius: pw.BorderRadius.circular(5)),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(e.value, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 2),
            pw.Text(e.key, style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700)),
          ]),
        )).toList(),
      );

  pw.Widget _emptyBlock(AnalyticsMonth month) => pw.Container(
        padding: const pw.EdgeInsets.all(12),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400)),
        child: pw.Text('Нет данных за выбранный месяц: ${_monthText(month)}'),
      );

  pw.Widget _salaryBlock(AnalyticsService service, String employeeId, SalaryBreakdown brk) => _buildKpiBlock({
        'Тип оплаты': _payTypeText(service, employeeId, brk),
        'Средняя ЗП': AnalyticsFormat.money(brk.averageShiftSalary),
        'Ночные': AnalyticsFormat.money(brk.nightBonus),
        'Компенсации': AnalyticsFormat.money(brk.compensation),
        'Соц. отчисления': AnalyticsFormat.money(brk.social),
        'Питание': AnalyticsFormat.money(brk.mealDeduction),
        'Аванс': AnalyticsFormat.money(brk.advance),
        'ЗП безнал': AnalyticsFormat.money(brk.cashless),
        'Дисциплина': AnalyticsFormat.money(brk.discipline),
        'Браки': AnalyticsFormat.money(brk.defect),
        'Итог ЗП': AnalyticsFormat.money(brk.total),
      });

  List<_EmployeePdfRow> _buildEmployeeRows(AnalyticsService service, PersonnelProvider personnel) {
    final state = service.state;
    final eventsByEmployee = <String, List<AnalyticsEvent>>{};
    for (final e in state.events) {
      eventsByEmployee.putIfAbsent(e.employeeId, () => []).add(e);
    }
    final claimsByEmployee = <String, int>{};
    for (final c in state.claims) {
      claimsByEmployee[c.employeeId] = (claimsByEmployee[c.employeeId] ?? 0) + 1;
    }
    final employees = personnel.employees.where((e) => !e.isFired).toList()
      ..sort((a, b) => _employeeName(a).compareTo(_employeeName(b)));
    return employees.map((employee) {
      final events = eventsByEmployee[employee.id] ?? const <AnalyticsEvent>[];
      final brk = _salaryForEmployee(service, employee.id, events);
      final payType = parsePayType(state.employeePayTypes[employee.id]);
      final workplaceNames = _workplaceSummary(personnel, events).join('; ');
      return _EmployeePdfRow(
        employee: employee,
        status: _statusName(service, employee.id),
        events: events,
        breakdown: brk,
        payTypeText: payType == null ? '—' : payTypeLabel(payType),
        payTypeAmount: _payTypeText(service, employee.id, brk),
        workplaces: workplaceNames.isEmpty ? '—' : workplaceNames,
        claims: claimsByEmployee[employee.id] ?? 0,
      );
    }).toList();
  }

  List<String> _workplaceSummary(PersonnelProvider personnel, List<AnalyticsEvent> events) {
    final byWp = <String, List<AnalyticsEvent>>{};
    for (final e in events) {
      byWp.putIfAbsent(e.workplaceId, () => []).add(e);
    }
    return byWp.entries.map((entry) {
      final wp = personnel.workplaceById(entry.key);
      final unit = wp == null ? 'ед.' : _unit(wp);
      return '${wp?.name ?? entry.key}: ${AnalyticsFormat.decimal(AnalyticsCalculator.totalQty(entry.value))} $unit';
    }).toList();
  }

  List<List<String>> _employeeWorkplaceRows(AnalyticsService service, PersonnelProvider personnel, String employeeId, List<AnalyticsEvent> events) {
    final claimsByWp = <String, int>{};
    for (final c in service.state.claims) {
      if (c.employeeId != employeeId) continue;
      final wpId = c.workplaceId ?? '';
      claimsByWp[wpId] = (claimsByWp[wpId] ?? 0) + 1;
    }
    final byWp = <String, List<AnalyticsEvent>>{};
    for (final e in events) {
      byWp.putIfAbsent(e.workplaceId, () => []).add(e);
    }
    return byWp.entries.map((entry) {
      final wp = personnel.workplaceById(entry.key);
      final unit = wp == null ? 'ед.' : _unit(wp);
      final useful = AnalyticsCalculator.usefulMinutes(entry.value);
      final qty = AnalyticsCalculator.totalQty(entry.value);
      return [
        wp?.name ?? entry.key,
        AnalyticsFormat.decimal(qty),
        unit,
        AnalyticsFormat.hoursMinutes(useful),
        '${AnalyticsFormat.decimal(useful > 0 ? qty / useful : 0)} $unit/мин',
        '${AnalyticsCalculator.countEventsOfType(entry.value, AnalyticsEventType.pause)}',
        '${AnalyticsCalculator.countEventsOfType(entry.value, AnalyticsEventType.problem)}',
        '${claimsByWp[entry.key] ?? 0}',
      ];
    }).toList();
  }

  List<_WorkplacePdfRow> _buildWorkplaceRows(AnalyticsService service, PersonnelProvider personnel) {
    final state = service.state;
    final byWp = <String, List<AnalyticsEvent>>{};
    for (final e in state.events) {
      byWp.putIfAbsent(e.workplaceId, () => []).add(e);
    }
    final claimsByWp = <String, int>{};
    for (final c in state.claims) {
      final wpId = c.workplaceId ?? '';
      if (wpId.isNotEmpty) claimsByWp[wpId] = (claimsByWp[wpId] ?? 0) + 1;
    }
    return personnel.workplaces.map((wp) {
      final events = byWp[wp.id] ?? const <AnalyticsEvent>[];
      final speed = AnalyticsCalculator.speedQtyPerMinute(events);
      return _WorkplacePdfRow(
        workplace: wp,
        coefficient: state.coefficients[wp.id] ?? 0,
        events: events,
        claims: claimsByWp[wp.id] ?? 0,
        kpd: KpdCalculator.compute(currentSpeed: speed, previousMonthsSpeeds: state.workplacePreviousSpeeds[wp.id] ?? const []),
      );
    }).toList();
  }

  SalaryBreakdown _salaryForEmployee(AnalyticsService service, String employeeId, List<AnalyticsEvent> events) {
    final state = service.state;
    final adj = state.adjustments[employeeId] ?? SalaryAdjustments.zero(employeeId, state.month.firstDay);
    return SalaryCalculator.compute(events: events, coefficients: state.coefficients, settings: state.settings, adjustments: adj, halfShiftMinutes: AnalyticsConstants.halfShiftMinutes);
  }

  String _payTypeText(AnalyticsService service, String employeeId, SalaryBreakdown brk) {
    final payType = parsePayType(service.state.employeePayTypes[employeeId]);
    if (payType == null) return '—';
    final amount = payType == PayType.salary ? brk.averageShiftSalary * brk.shiftsTotal : brk.pieceSalary;
    return '${payTypeLabel(payType)}: ${AnalyticsFormat.money(amount)}';
  }

  List<List<String>> _eventRows(List<AnalyticsEvent> events, PersonnelProvider personnel, {bool includeOrder = false}) {
    return events.map((e) {
      final workplace = personnel.workplaceById(e.workplaceId);
      final employee = _employeeById(personnel, e.employeeId);
      final duration = AnalyticsFormat.hoursMinutes(e.durationMinutes());
      final time = '${_hhmm(e.startTime)}-${e.endTime == null ? '—' : _hhmm(e.endTime!)}';
      if (includeOrder) {
        return [e.customer ?? '—', e.orderId.isEmpty ? '—' : e.orderId, employee == null ? e.employeeId : _employeeName(employee), time, duration, AnalyticsFormat.decimal(e.qty > 0 ? e.qty : e.setupQty), e.note ?? e.type.label];
      }
      return [e.type.label, '${e.customer ?? '—'} / ${workplace?.name ?? e.workplaceId}', time, duration, AnalyticsFormat.decimal(e.qty > 0 ? e.qty : e.setupQty), e.note ?? '—'];
    }).toList();
  }

  Map<int, List<AnalyticsEvent>> _eventsByDay(List<AnalyticsEvent> events) {
    final result = <int, List<AnalyticsEvent>>{};
    for (final e in events) {
      result.putIfAbsent(e.startTime.day, () => []).add(e);
    }
    return result;
  }

  Map<String, String> _employeeTotals(List<_EmployeePdfRow> rows) => {
        'Всего сотрудников': '${rows.length}',
        'Всего дневных смен': '${rows.fold<int>(0, (s, r) => s + r.breakdown.dayShifts)}',
        'Всего ночных смен': '${rows.fold<int>(0, (s, r) => s + r.breakdown.nightShifts)}',
        'Всего сделано': AnalyticsFormat.decimal(rows.fold<double>(0, (s, r) => s + AnalyticsCalculator.totalQty(r.events))),
        'Всего пауз': '${rows.fold<int>(0, (s, r) => s + AnalyticsCalculator.countEventsOfType(r.events, AnalyticsEventType.pause))}',
        'Всего проблем': '${rows.fold<int>(0, (s, r) => s + AnalyticsCalculator.countEventsOfType(r.events, AnalyticsEventType.problem))}',
        'Общий итог ЗП': AnalyticsFormat.money(rows.fold<double>(0, (s, r) => s + r.breakdown.total)),
        'Общая сумма компенсаций': AnalyticsFormat.money(rows.fold<double>(0, (s, r) => s + r.breakdown.compensation)),
        'Общая сумма удержаний': AnalyticsFormat.money(rows.fold<double>(0, (s, r) => s + r.breakdown.deductions)),
        'Общая сумма браков': AnalyticsFormat.money(rows.fold<double>(0, (s, r) => s + r.breakdown.defect)),
        'Общий аванс': AnalyticsFormat.money(rows.fold<double>(0, (s, r) => s + r.breakdown.advance)),
        'Общая сумма ЗП безнал': AnalyticsFormat.money(rows.fold<double>(0, (s, r) => s + r.breakdown.cashless)),
      };

  Map<String, String> _workplaceTotals(List<_WorkplacePdfRow> rows) => {
        'Всего рабочих мест': '${rows.length}',
        'Общее количество': AnalyticsFormat.decimal(rows.fold<double>(0, (s, r) => s + AnalyticsCalculator.totalQty(r.events))),
        'Общее полезное время': AnalyticsFormat.hoursMinutes(rows.fold<int>(0, (s, r) => s + AnalyticsCalculator.usefulMinutes(r.events))),
        'Общее количество пауз': '${rows.fold<int>(0, (s, r) => s + AnalyticsCalculator.countEventsOfType(r.events, AnalyticsEventType.pause))}',
        'Общее количество проблем': '${rows.fold<int>(0, (s, r) => s + AnalyticsCalculator.countEventsOfType(r.events, AnalyticsEventType.problem))}',
        'Средний КПД': '${rows.isEmpty ? 0 : (rows.fold<double>(0, (s, r) => s + r.kpd.kpdPercent) / rows.length).round()}%',
      };

  Future<String?> _saveSimplePdf({required String title, required AnalyticsMonth month, required String fileName, required String message}) async {
    final doc = await _createDocument();
    doc.addPage(pw.MultiPage(theme: _theme(), build: (_) => [_buildHeader(title, month), pw.Text(message)]));
    return _savePdfFile(await doc.save(), fileName);
  }

  Future<String?> _savePdfFile(Uint8List bytes, String fileName) async {
    String? path;
    try {
      path = await FilePicker.platform.saveFile(
        dialogTitle: 'Сохранить PDF',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        bytes: kIsWeb ? bytes : null,
      );
    } catch (error, stackTrace) {
      debugPrint('PDF save dialog failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    if (path == null || path.trim().isEmpty) {
      final dir = await _fallbackDirectory();
      path = '${dir.path}${Platform.pathSeparator}$fileName';
    }
    if (!path.toLowerCase().endsWith('.pdf')) path = '$path.pdf';
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<Directory> _fallbackDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    final dir = Directory('${documents.path}${Platform.pathSeparator}analytics_pdf');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _fileName(String prefix, AnalyticsMonth month) => '${_safeName(prefix)}_${month.year}_${month.month.toString().padLeft(2, '0')}.pdf';

  String _safeName(String value) {
    final trimmed = value.trim().replaceAll(RegExp(r'\s+'), '_');
    final safe = trimmed.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    return safe.isEmpty ? 'analytics' : safe;
  }

  String _employeeName(EmployeeModel e) => '${e.lastName} ${e.firstName} ${e.patronymic}'.trim().replaceAll(RegExp(r'\s+'), ' ');

  EmployeeModel? _employeeById(PersonnelProvider personnel, String id) {
    try {
      return personnel.employees.firstWhere((e) => e.id == id);
    } catch (_) {
      return null;
    }
  }

  String _statusName(AnalyticsService service, String employeeId) {
    final statusId = service.state.employeeStatusIds[employeeId] ?? '';
    for (final status in service.state.statuses) {
      if (status.id == statusId) return status.name;
    }
    return '—';
  }

  String _unit(WorkplaceModel wp) => wp.unit?.trim().isNotEmpty == true ? wp.unit!.trim() : 'ед.';
  String _monthText(AnalyticsMonth month) => '${month.month.toString().padLeft(2, '0')}.${month.year}';
  String _date(AnalyticsMonth month, int day) => '${day.toString().padLeft(2, '0')}.${month.month.toString().padLeft(2, '0')}.${month.year}';
  String _hhmm(DateTime dt) => '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  String _dateTime(DateTime dt) => '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year} ${_hhmm(dt)}';
}

class _EmployeePdfRow {
  const _EmployeePdfRow({
    required this.employee,
    required this.status,
    required this.events,
    required this.breakdown,
    required this.payTypeText,
    required this.payTypeAmount,
    required this.workplaces,
    required this.claims,
  });

  final EmployeeModel employee;
  final String status;
  final List<AnalyticsEvent> events;
  final SalaryBreakdown breakdown;
  final String payTypeText;
  final String payTypeAmount;
  final String workplaces;
  final int claims;

  List<String> get tableCells => [
        '${employee.lastName} ${employee.firstName}'.trim(),
        status,
        '${breakdown.dayShifts}',
        '${breakdown.nightShifts}',
        workplaces,
        AnalyticsFormat.decimal(AnalyticsCalculator.totalQty(events)),
        AnalyticsFormat.decimal(AnalyticsCalculator.totalSetupQty(events)),
        '${AnalyticsCalculator.countEventsOfType(events, AnalyticsEventType.pause)} / ${AnalyticsFormat.hoursMinutes(AnalyticsCalculator.pauseMinutes(events))}',
        '${AnalyticsCalculator.countEventsOfType(events, AnalyticsEventType.problem)} / ${AnalyticsFormat.hoursMinutes(AnalyticsCalculator.problemMinutes(events))}',
        '$claims',
        payTypeAmount,
        AnalyticsFormat.money(breakdown.averageShiftSalary),
        AnalyticsFormat.money(breakdown.nightBonus),
        AnalyticsFormat.money(breakdown.compensation),
        AnalyticsFormat.money(breakdown.social),
        AnalyticsFormat.money(breakdown.mealDeduction),
        AnalyticsFormat.money(breakdown.advance),
        AnalyticsFormat.money(breakdown.cashless),
        AnalyticsFormat.money(breakdown.discipline),
        AnalyticsFormat.money(breakdown.defect),
        AnalyticsFormat.money(breakdown.total),
        'Открыть',
      ];

  List<String> get salaryCells => [
        '${employee.lastName} ${employee.firstName}'.trim(),
        status,
        payTypeText,
        '${breakdown.dayShifts}',
        '${breakdown.nightShifts}',
        AnalyticsFormat.decimal(AnalyticsCalculator.totalQty(events)),
        AnalyticsFormat.money(breakdown.pieceSalary),
        payTypeText.toLowerCase().contains('оклад') ? AnalyticsFormat.money(breakdown.averageShiftSalary * breakdown.shiftsTotal) : '—',
        AnalyticsFormat.money(breakdown.averageShiftSalary),
        AnalyticsFormat.money(breakdown.nightBonus),
        AnalyticsFormat.money(breakdown.compensation),
        AnalyticsFormat.money(breakdown.social),
        AnalyticsFormat.money(breakdown.mealDeduction),
        AnalyticsFormat.money(breakdown.advance),
        AnalyticsFormat.money(breakdown.cashless),
        AnalyticsFormat.money(breakdown.discipline),
        AnalyticsFormat.money(breakdown.defect),
        AnalyticsFormat.money(breakdown.total),
      ];
}

class _WorkplacePdfRow {
  const _WorkplacePdfRow({
    required this.workplace,
    required this.coefficient,
    required this.events,
    required this.claims,
    required this.kpd,
  });

  final WorkplaceModel workplace;
  final double coefficient;
  final List<AnalyticsEvent> events;
  final int claims;
  final KpdResult kpd;

  List<String> get tableCells {
    final unit = workplace.unit?.trim().isNotEmpty == true ? workplace.unit!.trim() : 'ед.';
    final qty = AnalyticsCalculator.totalQty(events);
    final useful = AnalyticsCalculator.usefulMinutes(events);
    final orders = <String>{};
    for (final e in events) {
      if (e.type == AnalyticsEventType.work && e.orderId.isNotEmpty) orders.add(e.orderId);
    }
    return [
      workplace.name,
      unit,
      AnalyticsFormat.decimal(coefficient),
      AnalyticsFormat.decimal(qty),
      AnalyticsFormat.hoursMinutes(useful),
      '${AnalyticsFormat.decimal(useful > 0 ? qty / useful : 0)} $unit/мин',
      '${AnalyticsFormat.decimal(AnalyticsCalculator.totalSetupQty(events))} / ${AnalyticsFormat.hoursMinutes(AnalyticsCalculator.setupMinutes(events))}',
      '${orders.length}',
      '${AnalyticsCalculator.countEventsOfType(events, AnalyticsEventType.pause)} / ${AnalyticsFormat.hoursMinutes(AnalyticsCalculator.pauseMinutes(events))}',
      '${AnalyticsCalculator.countEventsOfType(events, AnalyticsEventType.problem)} / ${AnalyticsFormat.hoursMinutes(AnalyticsCalculator.problemMinutes(events))}',
      '$claims',
      '${kpd.kpdPercent.round()}%',
    ];
  }
}
