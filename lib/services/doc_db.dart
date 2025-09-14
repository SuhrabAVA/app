import 'package:supabase_flutter/supabase_flutter.dart';

/// Универсальная обёртка над таблицей `documents`.
/// Каждая сущность = значение в колонке `collection`, поля = JSON в `data`.
class DocDB {
  final SupabaseClient s = Supabase.instance.client;

  /// INSERT документа в коллекцию
  Future<Map<String, dynamic>> insert(
    String collection,
    Map<String, dynamic> data, {
    String? explicitId,
  }) async {
    final uid = s.auth.currentUser?.id;
    final row = <String, dynamic>{
      if (explicitId != null) 'id': explicitId,
      'collection': collection,
      'data': data,
      'created_by': uid,
    };

    final res = await s.from('documents').insert(row).select().single();
    return (res as Map<String, dynamic>);
  }

  /// SELECT всех документов коллекции (сортировка по created_at)
  Future<List<Map<String, dynamic>>> list(String collection) async {
    final res = await s
        .from('documents')
        .select()
        .eq('collection', collection)
        .order('created_at', ascending: false);
    return (res as List).cast<Map<String, dynamic>>();
  }

  /// SELECT по равенству JSON-поля: data->>key = value
  Future<List<Map<String, dynamic>>> whereEq(
    String collection,
    String key,
    dynamic value,
  ) async {
    final res = await s
        .from('documents')
        .select()
        .eq('collection', collection)
        .eq('data->>$key', value);
    return (res as List).cast<Map<String, dynamic>>();
  }

  /// Получить документ по id
  Future<Map<String, dynamic>?> getById(String id) async {
    final res = await s.from('documents').select().eq('id', id).maybeSingle();
    if (res == null) return null;
    return res as Map<String, dynamic>;
  }

  /// Полная замена JSON `data` по id
  Future<void> updateById(String id, Map<String, dynamic> newData) async {
    await s.from('documents').update({'data': newData}).eq('id', id);
  }

  /// Частичный апдейт JSON на клиенте
  Future<void> patchById(String id, Map<String, dynamic> patch) async {
    final row = await getById(id);
    if (row == null) return;
    final oldData = (row['data'] as Map?)?.cast<String, dynamic>() ?? {};
    await updateById(id, {...oldData, ...patch});
  }

  /// DELETE по id
  Future<void> deleteById(String id) async {
    await s.from('documents').delete().eq('id', id);
  }

  /// Realtime-подписка на изменения в таблице, фильтруем по collection в колбэке.
  RealtimeChannel listenCollection(
    String collection,
    void Function(Map<String, dynamic> row, PostgresChangeEvent event) onEvent,
  ) {
    return s
        .channel('docs:$collection')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'documents',
          // Без filter: ловим все события по таблице и фильтруем вручную
          callback: (payload) {
            final row =
                (payload.newRecord ?? payload.oldRecord ?? {}) as Map<String, dynamic>;
            if (row['collection'] == collection) {
              onEvent(row, payload.eventType);
            }
          },
        )
        .subscribe();
  }
}
