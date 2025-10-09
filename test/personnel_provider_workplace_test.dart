import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/personnel/personnel_provider.dart';
import 'package:sheet_clone/services/doc_db.dart';

class FakeDocDB extends DocDB {
  bool insertCalled = false;
  String? capturedCollection;
  Map<String, dynamic>? capturedData;

  @override
  Future<Map<String, dynamic>> insert(String collection, Map<String, dynamic> data, {String? explicitId}) async {
    insertCalled = true;
    capturedCollection = collection;
    capturedData = data;
    return {'id': explicitId ?? '1', 'collection': collection, 'data': data};
  }

  @override
  Future<List<Map<String, dynamic>>> list(String collection) async => [];
}

void main() {
  test('addWorkplace saves to documents', () async {
    final fakeDb = FakeDocDB();
    final provider = PersonnelProvider(docDb: fakeDb, bootstrap: false);
    await provider.addWorkplace(name: 'Test place', positionIds: ['p1']);

    expect(fakeDb.insertCalled, isTrue);
    expect(fakeDb.capturedCollection, 'workplaces');
    expect(fakeDb.capturedData?['name'], 'Test place');
    expect(provider.workplaces.any((w) => w.name == 'Test place'), isTrue);
  });
}