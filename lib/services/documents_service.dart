import 'package:supabase_flutter/supabase_flutter.dart';

class DocumentsService {
  final _sb = Supabase.instance.client;

  /// Универсальная вставка в public.documents
  /// collection: 'tmc', 'orders', 'positions' и т.д.
  Future<Map<String, dynamic>> insert({
    required String collection,
    required Map<String, dynamic> data,
    String? explicitId, // если хочешь вручную задать id (uuid!), обычно не нужно
  }) async {
    final uid = _sb.auth.currentUser?.id;

    final payload = <String, dynamic>{
      'collection': collection,
      'data': data,
      if (explicitId != null) 'id': explicitId,   // укажи ТОЛЬКО если это UUID
      if (uid != null) 'created_by': uid,         // иначе не добавляем — триггер подставит
    };

    final row = await _sb
        .from('documents')
        .insert(payload)
        .select('id, collection, data, created_by, created_at, updated_at')
        .single();

    return Map<String, dynamic>.from(row);
  }
}
