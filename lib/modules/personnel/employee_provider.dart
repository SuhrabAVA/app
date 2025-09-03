import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'employee_model.dart';

class EmployeeProvider with ChangeNotifier {
  final List<EmployeeModel> _employees = [];

  List<EmployeeModel> get employees => [..._employees];

  Future<void> fetchEmployees() async {
    final ref = FirebaseDatabase.instance.ref('employees');
    final snapshot = await ref.get();

    _employees.clear();
    if (snapshot.exists) {
      final data = Map<String, dynamic>.from(snapshot.value as Map);
      data.forEach((key, value) {
        final emp = EmployeeModel.fromJson(Map<String, dynamic>.from(value), key);
        _employees.add(emp);
      });
    }
    notifyListeners();
  }

  Future<void> addEmployee({
    required String lastName,
    required String firstName,
    required String patronymic,
    required String iin,
    required List<String> positionIds,
    required String comments,
    required File? image,
  }) async {
    String? photoUrl;
    if (image != null) {
      final ref = FirebaseStorage.instance
          .ref('employee_photos')
          .child('${DateTime.now().millisecondsSinceEpoch}.jpg');
      await ref.putFile(image);
      photoUrl = await ref.getDownloadURL();
    }

    final ref = FirebaseDatabase.instance.ref('employees').push();
    await ref.set({
      'lastName': lastName,
      'firstName': firstName,
      'patronymic': patronymic,
      'iin': iin,
      'photoUrl': photoUrl,
      'positionIds': positionIds,
      'isFired': false,
      'comments': comments,
    });

    await fetchEmployees();
  }
}
