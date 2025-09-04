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
      };

  factory EmployeeModel.fromJson(Map<String, dynamic> json, String id) {
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
    );
  }
}
