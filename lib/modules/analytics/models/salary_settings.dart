class SalarySettings {
  final String? id;
  final DateTime effectiveMonth;
  final double nightPercent;
  final double mealAmount;
  final double socialDefault;

  const SalarySettings({
    this.id,
    required this.effectiveMonth,
    required this.nightPercent,
    required this.mealAmount,
    required this.socialDefault,
  });

  factory SalarySettings.defaults(DateTime month) => SalarySettings(
        effectiveMonth: DateTime(month.year, month.month, 1),
        nightPercent: 0,
        mealAmount: 0,
        socialDefault: 0,
      );

  factory SalarySettings.fromMap(Map<String, dynamic> map) {
    double parseD(dynamic v) {
      if (v == null) return 0;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? 0;
    }

    DateTime parseDate(dynamic v) {
      if (v is DateTime) return v;
      if (v is String) return DateTime.parse(v);
      return DateTime.now();
    }

    return SalarySettings(
      id: map['id']?.toString(),
      effectiveMonth: parseDate(map['effective_month']),
      nightPercent: parseD(map['night_percent']),
      mealAmount: parseD(map['meal_amount']),
      socialDefault: parseD(map['social_default']),
    );
  }

  SalarySettings copyWith({
    double? nightPercent,
    double? mealAmount,
    double? socialDefault,
  }) =>
      SalarySettings(
        id: id,
        effectiveMonth: effectiveMonth,
        nightPercent: nightPercent ?? this.nightPercent,
        mealAmount: mealAmount ?? this.mealAmount,
        socialDefault: socialDefault ?? this.socialDefault,
      );
}
