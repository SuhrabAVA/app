class EmployeeModel {
  final String id;
  final String lastName;
  final String firstName;
  final String patronymic;
  final String iin;
  final String? photoUrl;
  final List<String> positionIds;
  bool isFired;
  final String comments;
  final String login;
  final String password;

  /// Оклад за одну смену (₸). Используется аналитикой для окладной части ЗП
  /// (смены × baseDaySalary). 0 = чисто сдельная оплата.
  final double baseDaySalary;

  EmployeeModel({
    required this.id,
    required this.lastName,
    required this.firstName,
    required this.patronymic,
    required this.iin,
    this.photoUrl,
    required this.positionIds,
    this.isFired = false,
    this.comments = '',
    this.login = '',
    this.password = '',
    this.baseDaySalary = 0,
  });

  Map<String, dynamic> toJson() => {
        'lastName': lastName,
        'firstName': firstName,
        'patronymic': patronymic,
        'iin': iin,
        'photoUrl': photoUrl,
        'positionIds': positionIds,
        'isFired': isFired,
        'comments': comments,
        'login': login,
        'password': password,
        'base_day_salary': baseDaySalary,
      };

  factory EmployeeModel.fromJson(Map<String, dynamic> json, String id) {
    double parseMoney(dynamic v) {
      if (v == null) return 0;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? 0;
    }

    return EmployeeModel(
      id: id,
      lastName: json['lastName'],
      firstName: json['firstName'],
      patronymic: json['patronymic'],
      iin: json['iin'],
      photoUrl: json['photoUrl'],
      positionIds: List<String>.from(json['positionIds'] ?? []),
      isFired: json['isFired'] ?? false,
      comments: json['comments'] ?? '',
      login: json['login'] ?? '',
      password: json['password'] ?? '',
      baseDaySalary:
          parseMoney(json['base_day_salary'] ?? json['baseDaySalary']),
    );
  }

  EmployeeModel copyWith({
    String? lastName,
    String? firstName,
    String? patronymic,
    String? iin,
    String? photoUrl,
    List<String>? positionIds,
    bool? isFired,
    String? comments,
    String? login,
    String? password,
    double? baseDaySalary,
  }) {
    return EmployeeModel(
      id: id,
      lastName: lastName ?? this.lastName,
      firstName: firstName ?? this.firstName,
      patronymic: patronymic ?? this.patronymic,
      iin: iin ?? this.iin,
      photoUrl: photoUrl ?? this.photoUrl,
      positionIds: positionIds ?? this.positionIds,
      isFired: isFired ?? this.isFired,
      comments: comments ?? this.comments,
      login: login ?? this.login,
      password: password ?? this.password,
      baseDaySalary: baseDaySalary ?? this.baseDaySalary,
    );
  }
}
