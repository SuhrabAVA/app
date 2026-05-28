import 'order_model.dart';

class OrderFormRuleResult {
  final bool hasForm;
  final bool isOldForm;
  final int? newFormNo;
  final String? formSeries;
  final String? formCode;

  const OrderFormRuleResult({
    required this.hasForm,
    required this.isOldForm,
    required this.newFormNo,
    required this.formSeries,
    required this.formCode,
  });
}

OrderFormRuleResult applyOrderFormRules({
  required OrderModel draft,
  required bool hasPaints,
  required bool userManuallySelectedFormType,
}) {
  if (!hasPaints || draft.hasForm || userManuallySelectedFormType) {
    return OrderFormRuleResult(
      hasForm: draft.hasForm,
      isOldForm: draft.isOldForm,
      newFormNo: draft.newFormNo,
      formSeries: draft.formSeries,
      formCode: draft.formCode,
    );
  }

  return const OrderFormRuleResult(
    hasForm: true,
    isOldForm: false,
    newFormNo: null,
    formSeries: null,
    formCode: null,
  );
}
