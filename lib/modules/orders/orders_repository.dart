// lib/modules/orders/orders_repository.dart (v3.1, paints fallback + events)
import 'dart:convert';
import 'dart:typed_data';
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
    final res = await _sb.from('order_paints').insert(rows).select('id');
    if (res is List) return res.length;
    return 0;
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
    required List<Map<String, dynamic>> paintUsages,
    String? quantityDone,
    String? comment,
    String? actor,
  }) async {
    await ensureSignedIn();
    final usages = paintUsages
        .where((row) =>
            row['write_off_now'] != false && row['writeOffNow'] != false)
        .map((row) {
          final usedQty = (row['used_qty'] is num)
              ? (row['used_qty'] as num).toDouble()
              : double.tryParse(
                  (row['used_qty'] ?? row['qty_g'] ?? row['qty_grams'] ?? '')
                      .toString()
                      .replaceAll(',', '.'),
                );
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
            'used_qty': usedQty ?? ((qtyKg ?? 0) * 1000),
          };
        })
        .where((row) =>
            (((row['paint_id'] ?? '') as String).isNotEmpty ||
                ((row['paint_name'] ?? '') as String).isNotEmpty) &&
            ((row['used_qty'] as num?)?.toDouble() ?? 0) > 0)
        .toList(growable: false);

    await _sb.rpc('complete_flex_printing_stage', params: {
      'p_task_id': taskId,
      'p_order_id': orderId,
      'p_stage_id': stageId,
      'p_employee_id': employeeId,
      'p_paint_usages': usages,
      'p_quantity_done': quantityDone,
      'p_comment': comment,
      'p_actor': actor ?? '',
    });
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

  Future<void> applyPaintUsage(
      {required String orderId,
      required List<PaintUsageUpdate> usages}) async {
    await ensureSignedIn();
    if (usages.isEmpty) return;

    for (final usage in usages) {
      try {
        await _sb.from('order_paints').update({
          'qty_kg': usage.kilograms,
        }).eq('id', usage.paintRowId);
      } catch (e) {
        rethrow;
      }
    }

    try {
      final row = await _sb
          .from('orders')
          .select('product')
          .eq('id', orderId)
          .maybeSingle();
      if (row == null) {
        return;
      }
      Map<String, dynamic> product;
      final raw = row['product'];
      if (raw is Map<String, dynamic>) {
        product = Map<String, dynamic>.from(raw);
      } else if (raw is Map) {
        product = Map<String, dynamic>.from(raw as Map);
      } else if (raw is String && raw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            product = Map<String, dynamic>.from(decoded as Map);
          } else {
            product = <String, dynamic>{};
          }
        } catch (_) {
          product = <String, dynamic>{};
        }
      } else {
        product = <String, dynamic>{};
      }

      final currentParams = (product['parameters'] ?? '').toString();
      final cleanRe =
          RegExp(r'(?:^|;\s*)Краска:\s*.+?(?=(?:;\s*Краска:|$))');
      var cleaned = currentParams.replaceAll(cleanRe, '').trim();
      if (cleaned.endsWith(';')) {
        cleaned = cleaned.substring(0, cleaned.length - 1).trim();
      }

      final buffer = <String>[];
      for (final usage in usages) {
        final info = usage.info?.trim() ?? '';
        final grams = usage.grams;
        if (grams <= 0) {
          continue;
        }
        final entry = info.isNotEmpty
            ? 'Краска: ${usage.name} ${_formatGrams(grams)} ($info)'
            : 'Краска: ${usage.name} ${_formatGrams(grams)}';
        buffer.add(entry);
      }

      String updated = cleaned;
      if (buffer.isNotEmpty) {
        final tail = buffer.join('; ');
        updated = updated.isEmpty ? tail : '$updated; $tail';
      }
      product['parameters'] = updated.trim();

      await _sb.from('orders').update({'product': product}).eq('id', orderId);
    } catch (e) {
      rethrow;
    }
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
