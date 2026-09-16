class WorkplaceCoefficient {
  final String id;
  final String workplaceId;

  /// Ставка за единицу для основного исполнителя, ₸.
  final double coefficient;

  /// Ставка за единицу для помощника совместной работы, ₸.
  ///
  /// null — помощник оплачивается по ставке основного исполнителя.
  ///
  /// Раньше здесь был процент скидки (`helper_percent`, -20 = «80% от
  /// основного»). Процент привязывал одну цену к другой, а на деле
  /// ответственность основного исполнителя выше не на ровную долю — теперь
  /// обе ставки задаются независимо.
  final double? helperCoefficient;

  final DateTime effectiveMonth;

  const WorkplaceCoefficient({
    required this.id,
    required this.workplaceId,
    required this.coefficient,
    this.helperCoefficient,
    required this.effectiveMonth,
  });

  /// Ставка помощника с подстановкой основной, если своя не задана.
  double get effectiveHelperCoefficient =>
      helperCoefficientOrMain(helperCoefficient, coefficient);

  factory WorkplaceCoefficient.fromMap(Map<String, dynamic> map) {
    double parseCoeff(dynamic v) {
      if (v == null) return 0;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? 0;
    }

    double? parseNullableCoeff(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      final text = v.toString().trim();
      if (text.isEmpty) return null;
      return double.tryParse(text);
    }

    DateTime parseDate(dynamic v) {
      if (v is DateTime) return v;
      if (v is String) return DateTime.parse(v);
      return DateTime.now();
    }

    final coefficient = parseCoeff(map['coefficient']);

    return WorkplaceCoefficient(
      id: (map['id'] ?? '').toString(),
      workplaceId: (map['workplace_id'] ?? '').toString(),
      coefficient: coefficient,
      helperCoefficient: parseNullableCoeff(map['helper_coefficient']),
      effectiveMonth: parseDate(map['effective_month']),
    );
  }
}

/// Ставка помощника с подстановкой основной, когда своя не задана.
///
/// Отрицательные и нечисловые значения не пропускаем: сдельная не должна
/// уходить в минус, а NaN тихо обнулил бы всю зарплату по рабочему месту.
double helperCoefficientOrMain(double? helper, double main) {
  final fallback = (main.isFinite && main > 0) ? main : 0.0;
  if (helper == null || !helper.isFinite || helper < 0) return fallback;
  return helper;
}
