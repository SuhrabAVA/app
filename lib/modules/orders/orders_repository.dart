// lib/modules/orders/orders_repository.dart (v3.1, paints fallback + events)
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
      'status': status ?? 'newOrder',
    };
    return _cleanForInsert(m);
  }
}

class PaintItem {
  final String name;
  final String? info;
  final double? qtyKg;
  const PaintItem({required this.name, this.info, this.qtyKg});

  Map<String, dynamic> toRow(String orderId) => _cleanForInsert({
        'order_id': orderId,
        'name': name,
        'info': info,
        'qty_kg': qtyKg,
      });
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
    double? singlePaintQtyKg,
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
          qtyKg: singlePaintQtyKg));
    }
    if (list.isNotEmpty) {
      await addPaints(orderId, list);
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
