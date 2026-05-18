// lib/modules/orders/orders_repository.dart (v3.1, paints fallback + events)
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class OrderFormData {
  final String manager;
  final String customer;
  final DateTime orderDate;
  final DateTime? dueDate;
  final bool isOldForm;
  final int? newFormNo;
  final double? actualQty;
  final String? comments;
  final bool contractSigned;
  final bool paymentDone;
  final String productName;
  final int? runSize;
  final int? widthMm;
  final int? heightMm;
  final int? depthMm;
  final String? materialName;
  final String? density;
  final String? leftoverOnStock;
  final String? rollName;
  final double? widthB;
  final double? lengthL;
  final Map<String, dynamic>? productParams;
  final String? handle;
  final String? cardboard;
  final double? makeready;
  final double? val;
  final String? queueId;
  final String? stageTemplateId;
  final String? status;
  final String queueBuildStatus;
  final String? selectedVStage;
  final String? selectedPStage;
  final Map<String, dynamic>? queueSignature;

  const OrderFormData({
    required this.manager,
    required this.customer,
    required this.orderDate,
    this.dueDate,
    required this.isOldForm,
    this.newFormNo,
    this.actualQty,
    this.comments,
    required this.contractSigned,
    required this.paymentDone,
    required this.productName,
    this.runSize,
    this.widthMm,
    this.heightMm,
    this.depthMm,
    this.materialName,
    this.density,
    this.leftoverOnStock,
    this.rollName,
    this.widthB,
    this.lengthL,
    this.productParams,
    this.handle,
    this.cardboard,
    this.makeready,
    this.val,
    this.queueId,
    this.stageTemplateId,
    this.status,
    this.queueBuildStatus = 'not_built',
    this.selectedVStage,
    this.selectedPStage,
    this.queueSignature,
  });

  Map<String, dynamic> toInsertMap() {
    final m = <String, dynamic>{
      'manager': manager,
      'customer': customer,
      'order_date': orderDate.toIso8601String(),
      if (dueDate != null) 'due_date': dueDate!.toIso8601String(),
      'is_old_form': isOldForm,
      'new_form_no': newFormNo,
      'actual_qty': actualQty,
      'comments': comments ?? '',
      'contract_signed': contractSigned,
      'payment_done': paymentDone,
      'product_name': productName,
      'run_size': runSize,
      'width_mm': widthMm,
      'height_mm': heightMm,
      'depth_mm': depthMm,
      'material_name': materialName,
      'density': density,
      'leftover_on_stock': leftoverOnStock,
      'roll_name': rollName,
      'width_b': widthB,
      'length_l': lengthL,
      'product_params': productParams,
      'handle': handle ?? '-',
      'cardboard': cardboard ?? 'нет',
      'makeready': makeready ?? 0,
      'val': val ?? 0,
      'queue_id': queueId,
      'stage_template_id': stageTemplateId,
      'status': status ?? 'draft',
      'queue_build_status': queueBuildStatus,
      'selected_v_stage': selectedVStage,
      'selected_p_stage': selectedPStage,
      'queue_signature': queueSignature,
    };
    return _cleanForInsert(m);
  }
}

class PaintItem {
  final String name;
  final String? info;
  final double? qtyGrams;
  const PaintItem({required this.name, this.info, this.qtyGrams});

  Map<String, dynamic> toRow(String orderId) => _cleanForInsert({
        'order_id': orderId,
        'name': name,
        'info': info,
        'qty_kg': qtyGrams == null ? null : qtyGrams! / 1000,
      });
}

class PaintUsageUpdate {
  final String paintRowId;
  final String name;
  final double grams;
  final String? info;

  const PaintUsageUpdate({
    required this.paintRowId,
    required this.name,
    required this.grams,
    this.info,
  });

  double get kilograms => grams / 1000.0;
}

class PaintPendingWriteoff {
  final String id;
  final String orderId;
  final String taskId;
  final String stageId;
  final String stageName;
  final String paintId;
  final String paintName;
  final double? plannedAmount;
  final double? actualUsedAmount;
  final String unit;
  final String status;

  const PaintPendingWriteoff({
    required this.id,
    required this.orderId,
    required this.taskId,
    required this.stageId,
    required this.stageName,
    required this.paintId,
    required this.paintName,
    this.plannedAmount,
    this.actualUsedAmount,
    required this.unit,
    required this.status,
  });

  factory PaintPendingWriteoff.fromMap(Map<String, dynamic> row) {
    return PaintPendingWriteoff(
      id: _topLevelTrimmedString(row, 'id'),
      orderId: _topLevelTrimmedString(row, 'order_id'),
      taskId: _topLevelTrimmedString(row, 'task_id'),
      stageId: _topLevelTrimmedString(row, 'stage_id'),
      stageName: _topLevelTrimmedString(row, 'stage_name'),
      paintId: _topLevelTrimmedString(row, 'paint_id'),
      paintName: _topLevelTrimmedString(row, 'paint_name'),
      plannedAmount: _topLevelReadDouble(row, 'planned_amount'),
      actualUsedAmount: _topLevelReadDouble(row, 'actual_used_amount'),
      unit: _topLevelTrimmedString(row, 'unit'),
      status: _topLevelTrimmedString(row, 'status'),
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
        'id': id,
        'order_id': orderId,
        'task_id': taskId,
        'stage_id': stageId,
        'stage_name': stageName,
        'paint_id': paintId,
        'paint_name': paintName,
        'planned_amount': plannedAmount,
        'actual_used_amount': actualUsedAmount,
        'unit': unit,
        'status': status,
      };
}

String _topLevelTrimmedString(Map<String, dynamic> row, String key) =>
    (row[key] ?? '').toString().trim();

double? _topLevelReadDouble(Map<String, dynamic> row, String key) {
  final value = row[key];
  if (value is num) return value.toDouble();
  return double.tryParse((value ?? '').toString().trim().replaceAll(',', '.'));
}

String _normalizePaintNameForMatching(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

class PdfAttachment {
  final Uint8List bytes;
  final String filename;
  final String mimeType;
  const PdfAttachment(
      {required this.bytes,
      required this.filename,
      this.mimeType = 'application/pdf'});
}

class OrdersRepository {
  final SupabaseClient _sb;
  OrdersRepository({SupabaseClient? supabaseClient})
      : _sb = supabaseClient ?? Supabase.instance.client;

  Future<void> ensureSignedIn() async {
    final auth = _sb.auth;
    if (auth.currentUser == null) {
      await auth.signInAnonymously();
    }
  }

  Future<String> createOrder({
    required OrderFormData data,
    List<PaintItem>? paints,
    PdfAttachment? pdf,
    String? singlePaintName,
    String? singlePaintInfo,
    double? singlePaintQtyGrams,
  }) async {
    await ensureSignedIn();
    final insertMap = data.toInsertMap();
    final inserted =
        await _sb.from('orders').insert(insertMap).select('id').single();
    final orderId = inserted['id'] as String;

    final list = <PaintItem>[];
    if (paints != null) list.addAll(paints);
    if (list.isEmpty &&
        singlePaintName != null &&
        singlePaintName.trim().isNotEmpty) {
      list.add(PaintItem(
          name: singlePaintName.trim(),
          info: singlePaintInfo,
          qtyGrams: singlePaintQtyGrams));
    }
    if (list.isNotEmpty) {
      await addPaints(orderId, list);
      await syncPaintReservations(
        orderId: orderId,
        paints: list
            .map((paint) => paint.toRow(orderId))
            .toList(growable: false),
      );
    }

    if (pdf != null) {
      final storagePath = await _uploadPdfToStorage(orderId, pdf);
      await _sb.from('order_files').insert(_cleanForInsert({
            'order_id': orderId,
            'storage_path': storagePath,
            'file_name': pdf.filename,
            'mime_type': pdf.mimeType,
            'file_size': pdf.bytes.length,
          }));
      try {
        final signed = await _sb.storage
            .from('order-pdfs')
            .createSignedUrl(storagePath, 60 * 60 * 24 * 7);
        await _sb.from('orders').update({'pdf_url': signed}).eq('id', orderId);
      } catch (_) {}
    }

    try {
      await logOrderEvent(
        orderId: orderId,
        eventType: 'created',
        message: 'Заказ создан',
        payload: insertMap,
      );
    } catch (_) {}

    return orderId;
  }

  Future<int> addPaints(String orderId, List<PaintItem> paints) async {
    if (paints.isEmpty) return 0;
    final rows = paints.map((p) => p.toRow(orderId)).toList();
    await saveOrderPaints(orderId: orderId, paints: rows);
    return rows.length;
  }

  Future<void> saveOrderPaints({
    required String orderId,
    required List<Map<String, dynamic>> paints,
  }) async {
    await ensureSignedIn();
    await _sb.rpc('save_order_paints', params: {
      'p_order_id': orderId,
      'p_paints': paints,
    });
  }

  Future<void> syncPaintReservations({
    required String orderId,
    required List<Map<String, dynamic>> paints,
    String? actor,
  }) async {
    await ensureSignedIn();
    final rows = paints
        .map((row) {
          final qtyKg = (row['qty_kg'] is num)
              ? (row['qty_kg'] as num).toDouble()
              : double.tryParse(
                  (row['qty_kg'] ?? '').toString().replaceAll(',', '.'),
                );
          final name =
              (row['paint_name'] ?? row['name'] ?? '').toString().trim();
          final paintId = (row['paint_id'] ?? row['material_id'] ?? '')
              .toString()
              .trim();
          return <String, dynamic>{
            if (paintId.isNotEmpty) 'paint_id': paintId,
            if (name.isNotEmpty) 'paint_name': name,
            'reserved_qty': (qtyKg ?? 0) * 1000,
          };
        })
        .where((row) =>
            (((row['paint_id'] ?? '') as String).isNotEmpty ||
                ((row['paint_name'] ?? '') as String).isNotEmpty) &&
            ((row['reserved_qty'] as num?)?.toDouble() ?? 0) > 0)
        .toList(growable: false);

    await _sb.rpc('sync_order_paint_reservations', params: {
      'p_order_id': orderId,
      'p_reservations': rows,
      'p_actor': actor ?? '',
    });
  }

  Future<void> releasePaintReservations({
    required String orderId,
    String reason = 'order_deleted',
    String? actor,
  }) async {
    await ensureSignedIn();
    await _sb.rpc('release_order_paint_reservations', params: {
      'p_order_id': orderId,
      'p_reason': reason,
      'p_actor': actor ?? '',
    });
  }

  Future<List<Map<String, dynamic>>> getPaintReservations(String orderId) async {
    final rows = await _sb
        .from('order_paint_reservations')
        .select('paint_id, paint_name, reserved_qty, used_qty, released_qty')
        .eq('order_id', orderId);
    if (rows is List) {
      return rows.cast<Map<String, dynamic>>();
    }
    return const [];
  }

  Future<List<Map<String, dynamic>>> getPendingPaintWriteoffs({
    String? excludeOrderId,
  }) async {
    final query = _sb
        .from('order_paint_pending_writeoffs')
        .select('id, order_id, task_id, stage_id, stage_name, paint_id, '
            'paint_name, planned_amount, actual_used_amount, unit, status')
        .eq('status', 'pending');
    final rows = (excludeOrderId ?? '').trim().isEmpty
        ? await query.order('created_at')
        : await query
            .neq('order_id', excludeOrderId!.trim())
            .order('created_at');
    if (rows is List) {
      return rows.cast<Map<String, dynamic>>();
    }
    return const [];
  }

  Future<List<PaintPendingWriteoff>> getPendingFlexPaintWriteoffs({
    required String currentOrderId,
    required List<String> currentPaintIds,
    required List<String> currentPaintNames,
  }) async {
    final normalizedCurrentOrderId = currentOrderId.trim();
    final paintIds = currentPaintIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    final paintNames = currentPaintNames
        .map(_normalizePaintNameForMatching)
        .where((name) => name.isNotEmpty)
        .toSet();

    if (paintIds.isEmpty && paintNames.isEmpty) {
      return const <PaintPendingWriteoff>[];
    }

    final query = _sb
        .from('order_paint_pending_writeoffs')
        .select('id, order_id, task_id, stage_id, stage_name, paint_id, '
            'paint_name, planned_amount, actual_used_amount, unit, status')
        .eq('status', 'pending');
    final rows = normalizedCurrentOrderId.isEmpty
        ? await query.order('created_at')
        : await query
            .neq('order_id', normalizedCurrentOrderId)
            .order('created_at');

    if (rows is! List) {
      return const <PaintPendingWriteoff>[];
    }

    return rows
        .cast<Map<String, dynamic>>()
        .map(PaintPendingWriteoff.fromMap)
        .where((row) {
          final hasMatchingPaintId =
              row.paintId.isNotEmpty && paintIds.contains(row.paintId);
          final hasMatchingPaintName = row.paintName.isNotEmpty &&
              paintNames.contains(_normalizePaintNameForMatching(row.paintName));
          return hasMatchingPaintId || hasMatchingPaintName;
        })
        .toList(growable: false);
  }

  Future<void> completeTaskStage({
    required String taskId,
    required String orderId,
    required String stageId,
    required String employeeId,
    String? quantityDone,
    String? comment,
    List<String> jointUserIds = const <String>[],
    String? actor,
  }) async {
    await ensureSignedIn();
    await _sb.rpc('complete_task_stage', params: {
      'p_task_id': taskId,
      'p_order_id': orderId,
      'p_stage_id': stageId,
      'p_employee_id': employeeId,
      'p_quantity_done': quantityDone,
      'p_comment': comment,
      'p_joint_user_ids': jointUserIds,
      'p_actor': actor ?? '',
    });
  }

  Future<void> completeFlexPrintingStage({
    required String taskId,
    required String orderId,
    required String stageId,
    required String employeeId,
    List<Map<String, dynamic>> currentOrderRows = const <Map<String, dynamic>>[],
    List<Map<String, dynamic>> pendingRows = const <Map<String, dynamic>>[],
    List<Map<String, dynamic>>? paintUsages,
    String? quantityDone,
    String? comment,
    String? actor,
  }) async {
    await ensureSignedIn();
    final effectiveCurrentRows = currentOrderRows.isNotEmpty
        ? currentOrderRows
        : (paintUsages ?? const <Map<String, dynamic>>[]);

    final currentRpcRows = effectiveCurrentRows
        .map((row) => _paintQueueRpcRow(
              row,
              fallbackOrderId: orderId,
              fallbackTaskId: taskId,
            ))
        .toList(growable: false);
    final pendingRpcRows = pendingRows
        .map((row) => _paintQueueRpcRow(row))
        .toList(growable: false);

    await _sb.rpc('complete_flex_printing_stage_with_paint_queue', params: {
      'p_task_id': taskId,
      'p_order_id': orderId,
      'p_stage_id': stageId,
      'p_employee_id': employeeId,
      'p_current_order_rows': currentRpcRows,
      'p_pending_rows': pendingRpcRows,
      'p_quantity_done': quantityDone,
      'p_comment': comment,
      'p_actor': actor ?? '',
    });

    await _applyPaintReservationUsage(<Map<String, dynamic>>[
      ...currentRpcRows,
      ...pendingRpcRows,
    ]);
  }

  Future<void> _applyPaintReservationUsage(
    List<Map<String, dynamic>> writeoffRows,
  ) async {
    final rowsToApply = writeoffRows.where((row) {
      final writeOffNow = row['write_off_now'] == true ||
          row['write_off_now']?.toString().toLowerCase() == 'true';
      final qty = _readDouble(row, const ['actual_used_amount', 'used_qty']) ?? 0;
      final sourceOrderId = _trimmedString(row, const ['source_order_id']);
      return writeOffNow && qty > 0 && sourceOrderId.isNotEmpty;
    }).toList(growable: false);
    if (rowsToApply.isEmpty) return;

    for (final row in rowsToApply) {
      final sourceOrderId = _trimmedString(row, const ['source_order_id']);
      final paintId = _trimmedString(row, const ['paint_id']);
      final paintName = _normalizePaintNameForMatching(
        _trimmedString(row, const ['paint_name']),
      );
      final usedQty =
          _readDouble(row, const ['actual_used_amount', 'used_qty']) ?? 0;
      if (sourceOrderId.isEmpty || usedQty <= 0) continue;
      if (paintId.isEmpty && paintName.isEmpty) continue;

      try {
        var query = _sb
            .from('order_paint_reservations')
            .select('id, paint_id, paint_name, reserved_qty, used_qty, released_qty')
            .eq('order_id', sourceOrderId);
        if (paintId.isNotEmpty) {
          query = query.eq('paint_id', paintId);
        }
        final response = await query;
        final reservations = response is List
            ? response
                .whereType<Map>()
                .map((raw) => Map<String, dynamic>.from(raw as Map))
                .where((reservation) {
                  if (paintId.isNotEmpty) return true;
                  return _normalizePaintNameForMatching(
                        (reservation['paint_name'] ?? '').toString(),
                      ) ==
                      paintName;
                })
                .toList(growable: true)
            : <Map<String, dynamic>>[];
        if (reservations.isEmpty) continue;

        var remainingToApply = usedQty;
        for (final reservation in reservations) {
          if (remainingToApply <= 0) break;
          final reserved = _readDouble(reservation, const ['reserved_qty']) ?? 0;
          final alreadyUsed = _readDouble(reservation, const ['used_qty']) ?? 0;
          final released = _readDouble(reservation, const ['released_qty']) ?? 0;
          final active = reserved - alreadyUsed - released;
          if (active <= 0) continue;
          final applyQty = active < remainingToApply ? active : remainingToApply;
          final nextUsed = alreadyUsed + applyQty;
          final reservationId = _trimmedString(reservation, const ['id']);
          var update = _sb
              .from('order_paint_reservations')
              .update({'used_qty': nextUsed});
          if (reservationId.isNotEmpty) {
            update = update.eq('id', reservationId);
          } else {
            update = update.eq('order_id', sourceOrderId);
            final reservationPaintId =
                _trimmedString(reservation, const ['paint_id']);
            if (reservationPaintId.isNotEmpty) {
              update = update.eq('paint_id', reservationPaintId);
            } else {
              update = update.eq('paint_name', reservation['paint_name']);
            }
          }
          await update;
          remainingToApply -= applyQty;
        }
      } catch (error) {
        debugPrint(
          '⚠️ Не удалось обновить резерв краски после списания: $error',
        );
      }
    }
  }

  Map<String, dynamic> _paintQueueRpcRow(
    Map<String, dynamic> row, {
    String? fallbackOrderId,
    String? fallbackTaskId,
  }) {
    final pendingWriteoffId = _trimmedString(row, const [
      'pending_writeoff_id',
      'pendingWriteoffId',
      'id',
    ]);
    final sourceOrderId = _trimmedString(row, const [
      'source_order_id',
      'sourceOrderId',
      'order_id',
      'orderId',
    ], fallback: fallbackOrderId);
    final sourceTaskId = _trimmedString(row, const [
      'source_task_id',
      'sourceTaskId',
      'task_id',
      'taskId',
    ], fallback: fallbackTaskId);
    final rawPaintId = _trimmedString(row, const [
      'paint_id',
      'paintId',
      'material_id',
    ]);
    final isValidPaintUuid = _isUuidString(rawPaintId);
    final paintId = isValidPaintUuid ? rawPaintId : '';
    final explicitPaintName = _trimmedString(row, const [
      'paint_name',
      'paintName',
      'name',
    ]);
    final paintName = explicitPaintName.isNotEmpty
        ? explicitPaintName
        : (isValidPaintUuid ? '' : rawPaintId);
    final unit = _trimmedString(row, const ['unit'], fallback: 'г');
    final actualUsedAmount = _readDouble(row, const [
      'actual_used_amount',
      'actualUsedAmount',
      'used_qty',
      'qty_g',
      'qty_grams',
    ]) ?? (_readDouble(row, const ['qty_kg']) == null
        ? null
        : _readDouble(row, const ['qty_kg'])! * 1000);
    final plannedAmount = _readDouble(row, const [
      'planned_amount',
      'plannedAmount',
      'planned_qty',
      'planned_qty_g',
      'reserved_qty',
    ]) ?? (_readDouble(row, const ['qty_kg']) == null
        ? null
        : _readDouble(row, const ['qty_kg'])! * 1000);
    final writeOffNow = row['write_off_now'] == true ||
        row['writeOffNow'] == true ||
        row['write_off_now']?.toString().toLowerCase() == 'true' ||
        row['writeOffNow']?.toString().toLowerCase() == 'true';

    return _cleanForInsert({
      if (pendingWriteoffId.isNotEmpty) 'pending_writeoff_id': pendingWriteoffId,
      if (sourceOrderId.isNotEmpty) 'source_order_id': sourceOrderId,
      if (sourceTaskId.isNotEmpty) 'source_task_id': sourceTaskId,
      if (paintId.isNotEmpty) 'paint_id': paintId,
      if (paintName.isNotEmpty) 'paint_name': paintName,
      'actual_used_amount': actualUsedAmount,
      'planned_amount': plannedAmount,
      'unit': unit.isEmpty ? 'г' : unit,
      'write_off_now': writeOffNow,
    });
  }

  bool _isUuidString(String value) {
    return RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    ).hasMatch(value.trim());
  }

  String _trimmedString(
    Map<String, dynamic> row,
    List<String> keys, {
    String? fallback,
  }) {
    for (final key in keys) {
      final value = (row[key] ?? '').toString().trim();
      if (value.isNotEmpty) return value;
    }
    return (fallback ?? '').trim();
  }

  double? _readDouble(Map<String, dynamic> row, List<String> keys) {
    for (final key in keys) {
      final value = row[key];
      if (value is num) return value.toDouble();
      final parsed = double.tryParse(
        (value ?? '').toString().trim().replaceAll(',', '.'),
      );
      if (parsed != null) return parsed;
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> getPaints(String orderId) async {
    final rows = await _sb
        .from('order_paints')
        .select()
        .eq('order_id', orderId)
        .order('created_at');
    if (rows is List) {
      return rows.cast<Map<String, dynamic>>();
    }
    return const [];
  }

  /// Returns planned paints from order_paints enriched with actual usage kept in
  /// order_paint_pending_writeoffs. The original qty_kg value remains the plan.
  Future<List<Map<String, dynamic>>> getPaintsWithPendingWriteoffs(
    String orderId,
  ) async {
    final paints = await getPaints(orderId);
    final writeoffRows = await _sb
        .from('order_paint_pending_writeoffs')
        .select('id, order_paint_id, order_id, task_id, stage_id, stage_name, '
            'paint_id, paint_name, planned_amount, actual_used_amount, unit, '
            'status, written_off_at')
        .eq('order_id', orderId)
        .inFilter('status', ['pending', 'written_off'])
        .order('created_at');
    final writeoffs = writeoffRows is List
        ? writeoffRows.cast<Map<String, dynamic>>()
        : const <Map<String, dynamic>>[];

    final writeoffsByPaintRowId = <String, List<Map<String, dynamic>>>{};
    final writeoffsByPaintName = <String, List<Map<String, dynamic>>>{};
    for (final writeoff in writeoffs) {
      final orderPaintId = (writeoff['order_paint_id'] ?? '').toString().trim();
      if (orderPaintId.isNotEmpty) {
        (writeoffsByPaintRowId[orderPaintId] ??= <Map<String, dynamic>>[])
            .add(writeoff);
      }
      final paintName = _normalizePaintNameForMatching(
        (writeoff['paint_name'] ?? '').toString(),
      );
      if (paintName.isNotEmpty) {
        (writeoffsByPaintName[paintName] ??= <Map<String, dynamic>>[])
            .add(writeoff);
      }
    }

    return paints.map((paint) {
      final paintRowId = (paint['id'] ?? '').toString().trim();
      final paintName = _normalizePaintNameForMatching(
        (paint['name'] ?? paint['paint_name'] ?? '').toString(),
      );
      final matchingWriteoffsById = <String, Map<String, dynamic>>{};
      for (final writeoff in <Map<String, dynamic>>[
        if (paintRowId.isNotEmpty)
          ...(writeoffsByPaintRowId[paintRowId] ??
              const <Map<String, dynamic>>[]),
        if (paintName.isNotEmpty)
          ...(writeoffsByPaintName[paintName] ??
              const <Map<String, dynamic>>[]),
      ]) {
        final id = (writeoff['id'] ?? '').toString();
        matchingWriteoffsById[id.isEmpty ? writeoff.hashCode.toString() : id] =
            writeoff;
      }
      final matchingWriteoffs = matchingWriteoffsById.values.toList();
      final actualUsedAmount = matchingWriteoffs.fold<double>(
        0,
        (total, writeoff) =>
            total + (_topLevelReadDouble(writeoff, 'actual_used_amount') ?? 0),
      );
      return <String, dynamic>{
        ...paint,
        'planned_qty_kg': paint['qty_kg'],
        'actual_used_amount': actualUsedAmount,
        'actual_used_unit': matchingWriteoffs.isEmpty
            ? 'г'
            : (matchingWriteoffs.last['unit'] ?? 'г').toString(),
        'writeoffs': matchingWriteoffs,
      };
    }).toList(growable: false);
  }

  Future<void> applyPaintUsage(
      {required String orderId,
      required List<PaintUsageUpdate> usages}) async {
    await ensureSignedIn();
    if (usages.isEmpty) return;

    final orderPaints = await getPaints(orderId);
    final plannedGramsByPaintRowId = <String, double>{};
    for (final paint in orderPaints) {
      final id = (paint['id'] ?? '').toString().trim();
      final qtyKg = _topLevelReadDouble(paint, 'qty_kg');
      if (id.isNotEmpty && qtyKg != null) {
        plannedGramsByPaintRowId[id] = qtyKg * 1000;
      }
    }

    final eventUsages = <Map<String, dynamic>>[];
    for (final usage in usages.where((usage) => usage.grams > 0)) {
      final paintRowId = usage.paintRowId.trim();
      final pendingRow = _cleanForInsert({
        'order_id': orderId,
        if (paintRowId.isNotEmpty) 'order_paint_id': paintRowId,
        'paint_name': usage.name,
        'planned_amount': plannedGramsByPaintRowId[paintRowId],
        'actual_used_amount': usage.grams,
        'unit': 'г',
        'status': 'pending',
        'comment': 'Фактический расход зафиксирован без изменения плана заказа',
      });

      final updateData = Map<String, dynamic>.from(pendingRow)
        ..remove('order_id')
        ..remove('order_paint_id')
        ..remove('status')
        ..['updated_at'] = DateTime.now().toIso8601String();
      dynamic updated;
      if (paintRowId.isNotEmpty) {
        updated = await _sb
            .from('order_paint_pending_writeoffs')
            .update(updateData)
            .eq('order_paint_id', paintRowId)
            .eq('status', 'pending')
            .select('id');
      }
      if (updated is! List || updated.isEmpty) {
        await _sb.from('order_paint_pending_writeoffs').insert(pendingRow);
      }

      eventUsages.add(<String, dynamic>{
        'order_paint_id': usage.paintRowId,
        'paint_name': usage.name,
        'actual_used_amount': usage.grams,
        'unit': 'г',
        if ((usage.info ?? '').trim().isNotEmpty) 'info': usage.info!.trim(),
      });
    }
    if (eventUsages.isEmpty) return;

    await logOrderEvent(
      orderId: orderId,
      eventType: 'paint_usage_applied',
      message: 'Зафиксирован фактический расход краски: '
          '${eventUsages.map((row) {
        final name = (row['paint_name'] ?? '').toString();
        final grams = (row['actual_used_amount'] as num).toDouble();
        return '$name ${_formatGrams(grams)}';
      }).join('; ')}',
      payload: {'paint_usages': eventUsages},
    );
  }

  Future<String?> getOrderCustomer(String orderId) async {
    await ensureSignedIn();
    try {
      final row = await _sb
          .from('orders')
          .select('customer')
          .eq('id', orderId)
          .maybeSingle();
      if (row == null) return null;
      final value = row['customer'];
      if (value == null) return null;
      return value.toString();
    } catch (_) {
      return null;
    }
  }

  Future<void> logOrderEvent({
    required String orderId,
    required String eventType,
    String? message,
    Map<String, dynamic>? payload,
  }) async {
    final row = _cleanForInsert({
      'order_id': orderId,
      'event_type': eventType,
      'message': message,
      'description': message,
      'payload': payload,
    });
    await _sb.from('order_events').insert(row);
  }

  Future<String> _uploadPdfToStorage(String orderId, PdfAttachment pdf) async {
    final uuid = const Uuid().v4();
    final ext = _fileExt(pdf.filename);
    final path = 'orders/$orderId/$uuid$ext';
    await _sb.storage.from('order-pdfs').uploadBinary(path, pdf.bytes,
        fileOptions: FileOptions(
          contentType: pdf.mimeType,
          upsert: true,
        ));
    return path;
  }
}

String _formatGrams(double grams) {
  final precision = grams % 1 == 0 ? 0 : 2;
  final fixed = grams.toStringAsFixed(precision);
  final trimmed = fixed
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
  return '$trimmed г';
}

Map<String, dynamic> _cleanForInsert(Map<String, dynamic> src) {
  final m = Map<String, dynamic>.from(src);
  final keysToRemove = <String>[];
  m.forEach((k, v) {
    if (v == null) {
      keysToRemove.add(k);
    } else if (v is String && v.trim().isEmpty) {
      keysToRemove.add(k);
    }
  });
  for (final k in keysToRemove) {
    m.remove(k);
  }
  return m;
}

String _fileExt(String filename) {
  final i = filename.lastIndexOf('.');
  if (i == -1 || i == filename.length - 1) return '.pdf';
  final ext = filename.substring(i);
  if (ext.length > 8) return '.pdf';
  return ext;
}
