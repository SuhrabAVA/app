import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../utils/auth_helper.dart';
import '../../chat/chat_message.dart';
import '../../chat/chat_provider.dart';
import '../../personnel/personnel_provider.dart';
import '../../tasks/quantity_status_service.dart';
import '../../tasks/task_provider.dart';
import '../models/analytics_event.dart';
import '../models/claim_model.dart';
import '../repositories/claims_repository.dart';

/// Правка зафиксированного количества техлидом прямо из аналитики.
///
/// Сотрудник иногда вводит неверное число. Исправление должно попасть сразу
/// в аналитику сотрудника, в комментарии заказа и — если этап формирует
/// фактическое количество — в сам заказ. Всё это делает
/// [TaskProvider.editQuantityRecord]; диалог только собирает ввод.
///
/// Возвращает true, если правка сохранена: вызывающий перезагружает месяц.
Future<bool> showQuantityEditDialog({
  required BuildContext context,
  required AnalyticsEvent event,
  required String workplaceUnit,
}) async {
  // Автор правки — тот, кто вошёл в приложение. Раньше сюда приходил
  // permission.currentEmployeeId, но это ФИЛЬТР «показывать только себя»:
  // техлиду он равен null (см. admin_panel.dart), и правка не открывалась
  // вовсе. У техлида AuthHelper.currentUserId == 'tech_leader'.
  final editorId = (AuthHelper.currentUserId ?? '').trim();
  final editorName = (AuthHelper.currentUserName ?? '').trim();
  if (editorId.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Не удалось определить, кто правит. Войдите заново.'),
      ),
    );
    return false;
  }
  final sources = event.qtySources
      .where((s) => s.commentId.trim().isNotEmpty)
      .toList(growable: false);
  if (sources.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'У этой строки нет исходной записи количества — править нечего.',
        ),
      ),
    );
    return false;
  }

  // Одно событие вбирает несколько записей (перерывы + завершение): сначала
  // выбираем, какую именно исправляем.
  final AnalyticsQtySource? source = sources.length == 1
      ? sources.first
      : await showDialog<AnalyticsQtySource>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: const Text('Какую запись исправляем?'),
            children: [
              for (final s in sources)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, s),
                  child: Text(
                    '${_hhmm(s.timestamp)} · ${_typeLabel(s.type)} · '
                    '${formatQuantityNumber(s.qty)} $workplaceUnit',
                  ),
                ),
            ],
          ),
        );
  if (source == null || !context.mounted) return false;

  final taskProvider = context.read<TaskProvider>();

  final payload = tryDecodeQuantityPayload(source.rawText);
  // Единица ХРАНЕНИЯ, а не показа: на упаковке сотрудник вводит штуки, а в
  // аналитике засчитываются упаковки. Правится именно введённое число.
  final payloadUnit = (payload?['unit'] ?? '').toString().trim();
  final storedUnit = payloadUnit.isNotEmpty ? payloadUnit : workplaceUnit;
  final packSize = _numberOf(payload?['pack_size']);
  final storedActual = quantityActualFromText(source.rawText) ?? source.qty;

  final valueController = TextEditingController(
    text: formatQuantityNumber(storedActual),
  );
  final reasonController = TextEditingController();
  // Кому претензия, выбирать не из чего: правим запись конкретного
  // сотрудника, он и есть адресат.
  final claimEmployeeId = event.employeeId.trim();
  final claimEmployeeName = _employeeName(
    context.read<PersonnelProvider>(),
    claimEmployeeId,
  );
  // Свой экземпляр: ChatProvider живёт внутри вкладки чата, в дереве
  // аналитики его нет. Нужен ради отправки сообщения; закрываем сразу после
  // диалога — dispose снимает подписки.
  final chat = ChatProvider();
  final messenger = ScaffoldMessenger.of(context);

  final saved = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          String? error;
          var busy = false;
          return StatefulBuilder(
            builder: (ctx, setState) {
              // Подсказка по упаковкам: сотруднику засчитываются они, а не
              // введённые штуки, и техлид должен видеть, что получится.
              String packsHint() {
                if (packSize == null || packSize <= 0) return '';
                final entered = double.tryParse(
                  valueController.text.trim().replaceAll(',', '.'),
                );
                final packs = entered == null
                    ? null
                    : packCountForPieces(pieces: entered, packSize: packSize);
                if (packs == null) return '';
                return 'Засчитается упаковок: $packs '
                    '(по ${formatQuantityNumber(packSize)} шт)';
              }

              final hint = packsHint();
              return AlertDialog(
                title: const Text('Исправить количество'),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Сейчас записано: '
                        '${quantityDisplayText(source.rawText)}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: valueController,
                        autofocus: true,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: storedUnit.isEmpty
                              ? 'Новое количество'
                              : 'Новое количество, $storedUnit',
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: (_) => setState(() => error = null),
                      ),
                      if (hint.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          hint,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextField(
                        controller: reasonController,
                        decoration: const InputDecoration(
                          labelText: 'Причина правки',
                          hintText: 'Например: описался, пересчитали на складе',
                          border: OutlineInputBorder(),
                        ),
                        maxLines: 2,
                        onChanged: (_) => setState(() => error = null),
                      ),
                      if (claimEmployeeId.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Icon(
                              Icons.report_gmailerrorred_outlined,
                              size: 18,
                              color: Colors.red.shade700,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Претензия: $claimEmployeeName',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.red.shade700,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: busy ? null : () => Navigator.pop(ctx, false),
                    child: const Text('Отмена'),
                  ),
                  ElevatedButton(
                    onPressed: busy
                        ? null
                        : () async {
                            final raw =
                                valueController.text.trim().replaceAll(',', '.');
                            final parsed = double.tryParse(raw);
                            if (parsed == null) {
                              setState(
                                () => error = 'Количество должно быть числом.',
                              );
                              return;
                            }
                            setState(() {
                              busy = true;
                              error = null;
                            });
                            try {
                              final result =
                                  await taskProvider.editQuantityRecord(
                                taskId: event.taskId,
                                commentId: source.commentId,
                                newActual: parsed,
                                reason: reasonController.text,
                                editorUserId: editorId,
                                editorName: editorName,
                              );
                              // Претензии заводим только после успешной
                              // правки: иначе сотрудник получил бы претензию
                              // за число, которое так и не изменилось.
                              final claimError = await _createClaim(
                                chat: chat,
                                result: result,
                                employeeId: claimEmployeeId,
                                employeeName: claimEmployeeName,
                                editorId: editorId,
                                editorName: editorName,
                              );
                              if (claimError != null) {
                                messenger.showSnackBar(
                                  SnackBar(content: Text(claimError)),
                                );
                              }
                              if (ctx.mounted) Navigator.pop(ctx, true);
                            } catch (e) {
                              setState(() {
                                busy = false;
                                error = e
                                    .toString()
                                    .replaceFirst('Exception: ', '');
                              });
                            }
                          },
                    child: busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Сохранить'),
                  ),
                ],
              );
            },
          );
        },
      ) ??
      false;

  valueController.dispose();
  reasonController.dispose();
  chat.dispose();
  return saved;
}

/// Претензия сотруднику, чью запись исправили, + сообщение в общий чат.
///
/// Адресат не выбирается: правится запись конкретного сотрудника, он и есть
/// тот, кто ввёл неверное число.
///
/// Порядок тот же, что у претензии из чата (см. input_bar): сначала строка
/// претензии, затем сообщение с `claim_targets` — бейдж в чате рисуется по
/// ним. Если сообщение не ушло, претензия откатывается: висеть в аналитике
/// без следа в чате она не должна.
///
/// Возвращает текст ошибки для показа или null, если всё прошло. Саму правку
/// количества провал претензии не отменяет — она уже записана.
Future<String?> _createClaim({
  required ChatProvider chat,
  required QuantityEditResult result,
  required String employeeId,
  required String employeeName,
  required String editorId,
  required String editorName,
}) async {
  if (employeeId.isEmpty) return null;

  // Отправителя проверяем до вставки претензий: без него сообщение в чат не
  // уйдёт, и претензии пришлось бы откатывать. Подставного автора не
  // придумываем — претензия это обвинение, оно должно быть именным.
  final senderId = Supabase.instance.client.auth.currentUser?.id.trim() ?? '';
  if (senderId.isEmpty) {
    return 'Количество исправлено, но претензия не создана: '
        'не удалось определить отправителя.';
  }

  final repo = ClaimsRepository();
  final messageId = chat.newMessageId();
  var created = const <ClaimModel>[];
  try {
    created = await repo.createForChatMessage(
      employeeIds: [employeeId],
      messageId: messageId,
      description: result.summary,
      createdBy: editorId,
      authorName: editorName,
      orderId: result.orderId,
      workplaceId: result.stageId,
      commentId: result.commentId,
    );
  } catch (error) {
    debugPrint('Claim insert failed for quantity edit: $error');
    return 'Количество исправлено, но претензия не создана.';
  }

  try {
    await chat.sendText(
      roomId: 'general',
      // chat_messages.sender_id — uuid Supabase-пользователя, как во всех
      // остальных отправках. AuthHelper даёт для техлида строку
      // 'tech_leader': она годится в claims.created_by (там text), но на
      // вставке сообщения упала бы по типу колонки.
      senderId: senderId,
      senderName: editorName.isEmpty ? null : editorName,
      text: result.summary,
      messageId: messageId,
      claimTargets: [
        ChatClaimTarget(id: employeeId, name: employeeName),
      ],
    );
  } catch (error) {
    debugPrint('Claim message failed for quantity edit: $error');
    try {
      await repo.deleteByIds([for (final c in created) c.id]);
    } catch (rollbackError) {
      debugPrint('Claim rollback failed: $rollbackError');
    }
    return 'Количество исправлено, но претензия не создана.';
  }
  return null;
}

/// ФИО сотрудника для бейджа претензии; при неизвестном id — сам id.
String _employeeName(PersonnelProvider personnel, String employeeId) {
  if (employeeId.isEmpty) return '';
  try {
    final e = personnel.employees.firstWhere((x) => x.id == employeeId);
    final name = '${e.lastName} ${e.firstName}'.trim();
    return name.isEmpty ? employeeId : name;
  } catch (_) {
    return employeeId;
  }
}

String _typeLabel(String type) {
  switch (type) {
    case 'quantity_done':
      return 'завершение';
    case 'quantity_team_total':
      return 'итог бригады';
    case 'quantity_share':
      return 'перерыв';
    default:
      return type;
  }
}

String _hhmm(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';

double? _numberOf(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.replaceAll(',', '.'));
  return null;
}
