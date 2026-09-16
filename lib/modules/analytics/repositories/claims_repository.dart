import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/claim_model.dart';

class ClaimsRepository {
  ClaimsRepository({SupabaseClient? client}) : _injectedClient = client;

  final SupabaseClient? _injectedClient;

  // Ленивое разрешение клиента: конструктор вызывается в инициализаторах полей
  // виджетов (например, поля ввода чата), и обращение к Supabase.instance
  // прямо там роняло ассертом любой виджет-тест такого экрана.
  late final SupabaseClient _client =
      _injectedClient ?? Supabase.instance.client;

  static const _cols =
      'id, order_id, comment_id, employee_id, workplace_id, description, '
      'created_by, created_at, source, message_id, file_url, file_mime, '
      'author_name';

  /// Все претензии за месяц.
  Future<List<ClaimModel>> listForMonth(DateTime month) async {
    final firstDay = DateTime(month.year, month.month, 1);
    final nextMonthFirst = DateTime(month.year, month.month + 1, 1);
    final List<dynamic> rows = await _client
        .from('claims')
        .select(_cols)
        .gte('created_at', firstDay.toUtc().toIso8601String())
        .lt('created_at', nextMonthFirst.toUtc().toIso8601String());
    return rows
        .whereType<Map>()
        .map((m) => ClaimModel.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<ClaimModel> create({
    required String orderId,
    required String employeeId,
    String? commentId,
    String? workplaceId,
    String? description,
    String? createdBy,
  }) async {
    final result = await _client
        .from('claims')
        .insert({
          'order_id': orderId,
          'employee_id': employeeId,
          'comment_id': commentId,
          'workplace_id': workplaceId,
          'description': description,
          'created_by': createdBy,
        })
        .select()
        .single();
    return ClaimModel.fromMap(Map<String, dynamic>.from(result));
  }

  /// Претензии из чата: по одной строке на каждого выбранного сотрудника,
  /// одним batch-insert (либо создаются все, либо ни одной).
  /// [orderId] / [workplaceId] / [commentId] заполняются, когда претензия
  /// заводится не «из воздуха», а по конкретной записи — например при правке
  /// количества техлидом. `source` остаётся 'chat': сообщение в чате всё
  /// равно создаётся, и по нему рисуется бейдж (ограничение в БД: у 'chat'
  /// обязателен message_id, а order_id при этом не запрещён).
  Future<List<ClaimModel>> createForChatMessage({
    required List<String> employeeIds,
    required String messageId,
    String? fileUrl,
    String? fileMime,
    String? description,
    String? createdBy,
    String? authorName,
    String? orderId,
    String? workplaceId,
    String? commentId,
  }) async {
    if (employeeIds.isEmpty) return const [];
    final createdAt = DateTime.now().toUtc().toIso8601String();
    final rows = [
      for (final employeeId in employeeIds)
        {
          'employee_id': employeeId,
          'source': 'chat',
          'message_id': messageId,
          'file_url': fileUrl,
          'file_mime': fileMime,
          'description': description,
          'created_by': createdBy,
          'author_name': authorName,
          'created_at': createdAt,
          if (orderId != null && orderId.isNotEmpty) 'order_id': orderId,
          if (workplaceId != null && workplaceId.isNotEmpty)
            'workplace_id': workplaceId,
          if (commentId != null && commentId.isNotEmpty) 'comment_id': commentId,
        },
    ];
    final List<dynamic> result =
        await _client.from('claims').insert(rows).select(_cols);
    return result
        .whereType<Map>()
        .map((m) => ClaimModel.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// Откат только что созданных претензий (сообщение не отправилось).
  /// Требует delete-политику RLS; без неё молча удалит 0 строк.
  Future<void> deleteByIds(List<String> ids) async {
    if (ids.isEmpty) return;
    await _client.from('claims').delete().inFilter('id', ids);
  }
}
