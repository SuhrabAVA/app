import 'package:supabase_flutter/supabase_flutter.dart';

class DocDB {
  final SupabaseClient s = Supabase.instance.client;

  Future<void> insert(String collection, Map<String, dynamic> data) async {
    final uid = s.auth.currentUser?.id;
    await s.from('documents').insert({
      'collection': collection,
      'data': data,
      'created_by': uid, // важно для RLS
    });
  }

  RealtimeChannel listenCollection(
      String collection, void Function(Map) onEvent) {
    return s
        .channel('docs:$collection')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'documents',
          filter: PostgresChangeFilter.eq('collection', collection),
          callback: (payload) {
            final row = payload.newRecord ?? payload.oldRecord ?? {};
            onEvent(row);
          },
        )
        .subscribe();
  }

  Future<List<Map<String, dynamic>>> list(String collection) async {
    final res = await s.from('documents').select().eq('collection', collection);
    return (res as List).cast<Map<String, dynamic>>();
  }
}
