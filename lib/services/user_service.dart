
import 'package:supabase_flutter/supabase_flutter.dart';
import 'doc_db.dart';

class UserService {
  final DocDB _db = DocDB();

  /// Создаёт в `documents` пользователя Технический Лидер, если его еще нет.
  /// Документ лежит в коллекции `users` и имеет id = 'tech_leader'.
  Future<void> ensureTechLeaderExists() async {
    try {
      // пробуем прочитать документ по явному id
      final res = await Supabase.instance.client
          .from('documents')
          .select()
          .eq('id', 'tech_leader')
          .maybeSingle();
      if (res != null) return;

      await _db.insert(
        'users',
        {
          'id': 'tech_leader',
          'name': 'Технический лидер',
          'role': 'tech_lead',
          'password': '123123', // соответствует login_screen
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        },
        explicitId: 'tech_leader',
      );
    } catch (e) {
      // если RLS запретит — просто пропустим; можно создать вручную в Studio
    }
  }
}
