import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/financialMessageParser.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:flutter/material.dart';

class FinancialImportPage extends StatefulWidget {
  const FinancialImportPage({super.key});

  static String label(BuildContext context, String english, String arabic) =>
      Localizations.localeOf(context).languageCode == 'ar' ? arabic : english;

  @override
  State<FinancialImportPage> createState() => _FinancialImportPageState();
}

class _FinancialImportPageState extends State<FinancialImportPage> {
  final _message = TextEditingController();
  late var _imports = database.getImportedFinancialEvents();
  bool _busy = false;

  String label(String english, String arabic) =>
      FinancialImportPage.label(context, english, arabic);

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  void _notify(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted)
        setState(() => _imports = database.getImportedFinancialEvents());
    } catch (_) {
      if (mounted)
        _notify(label('Could not save the import.', 'تعذّر حفظ الاستيراد.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stage() => _run(() async {
    final raw = _message.text.trim();
    final parsed = FinancialMessageParser.parse(raw);
    if (parsed.amount == null || parsed.direction == null) {
      _notify(
        label(
          'Enter a message with one amount, its currency, and a transaction type.',
          'أدخل رسالة تحتوي على مبلغ واحد وعملته ونوع المعاملة.',
        ),
      );
      return;
    }
    await database.stageImportedFinancialEvent(
      eventPk: uuid.v4(),
      sourceType: 'manual',
      rawText: raw,
      occurredAt: DateTime.now(),
      amount: parsed.amount,
      currency: parsed.currency,
      direction: parsed.direction,
      merchant: parsed.merchant,
      identifierLast4: parsed.lastFour,
      confidence: parsed.confidence,
    );
    if (mounted) _message.clear();
  });

  Future<void> _review(Map<String, dynamic> event) => _run(() async {
    final wallets = (await database.getAllWallets())
        .where((wallet) => wallet.currency?.toLowerCase() == event['currency'])
        .toList();
    final categories = (await database.getAllCategories())
        .where(
          (category) =>
              category.categoryPk != '0' &&
              category.income == (event['direction'] == 'credit'),
        )
        .toList();
    if (!mounted) return;
    if (wallets.isEmpty || categories.isEmpty) {
      _notify(
        label(
          'Add an account in this currency and a matching category.',
          'أضف حسابًا بهذه العملة وتصنيفًا مناسبًا.',
        ),
      );
      return;
    }
    String? walletPk;
    String? categoryPk;
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(label('Approve transaction', 'اعتماد المعاملة')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_amountLabel(event)),
              Text(
                label(
                  'The transaction uses the date this message was pasted.',
                  'ستُسجّل المعاملة بتاريخ لصق الرسالة.',
                ),
              ),
              DropdownButton<String>(
                isExpanded: true,
                hint: Text(label('Account', 'الحساب')),
                value: walletPk,
                items: wallets
                    .map(
                      (wallet) => DropdownMenuItem(
                        value: wallet.walletPk,
                        child: Text(wallet.name),
                      ),
                    )
                    .toList(),
                onChanged: (value) => update(() => walletPk = value),
              ),
              DropdownButton<String>(
                isExpanded: true,
                hint: Text(label('Category', 'التصنيف')),
                value: categoryPk,
                items: categories
                    .map(
                      (category) => DropdownMenuItem(
                        value: category.categoryPk,
                        child: Text(category.name),
                      ),
                    )
                    .toList(),
                onChanged: (value) => update(() => categoryPk = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(label('Cancel', 'إلغاء')),
            ),
            FilledButton(
              onPressed: walletPk == null || categoryPk == null
                  ? null
                  : () => Navigator.pop(dialogContext, true),
              child: Text(label('Save transaction', 'حفظ المعاملة')),
            ),
          ],
        ),
      ),
    );
    if (approved != true || !mounted) return;
    final title = event['merchant'] as String?;
    final result = await database.approveImportedFinancialEvent(
      eventPk: event['event_pk'] as String,
      transactionPk: uuid.v4(),
      categoryFk: categoryPk!,
      walletPk: walletPk,
      title: title == null || title.trim().isEmpty
          ? label('Imported transaction', 'معاملة مستوردة')
          : String.fromCharCodes(title.runes.take(NAME_LIMIT)),
    );
    if (mounted) {
      _notify(
        result == 'duplicate'
            ? label(
                'A matching transaction already exists.',
                'توجد معاملة مطابقة بالفعل.',
              )
            : label('Transaction saved.', 'تم حفظ المعاملة.'),
      );
    }
  });

  String _amountLabel(Map<String, dynamic> event) {
    final prefix = event['direction'] == 'debit' ? '−' : '+';
    final amount = event['amount'];
    final currency = (event['currency'] as String?)?.toUpperCase();
    return amount == null || currency == null
        ? label('Incomplete amount', 'المبلغ غير مكتمل')
        : '$prefix$amount $currency';
  }

  @override
  Widget build(BuildContext context) {
    return PageFramework(
      title: label('Bank message import', 'استيراد الرسائل البنكية'),
      capitalizeTitle: false,
      listWidgets: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _message,
                minLines: 2,
                maxLines: 4,
                maxLength: 2000,
                decoration: InputDecoration(
                  labelText: label(
                    'Paste a transaction message',
                    'الصق رسالة المعاملة',
                  ),
                ),
              ),
              FilledButton(
                onPressed: _busy ? null : _stage,
                child: Text(label('Add for review', 'إضافة للمراجعة')),
              ),
            ],
          ),
        ),
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _imports,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return ListTile(
                title: Text(
                  label(
                    'Could not load imports.',
                    'تعذّر تحميل الرسائل المستوردة.',
                  ),
                ),
              );
            }
            if (!snapshot.hasData) return const LinearProgressIndicator();
            if (snapshot.data!.isEmpty) {
              return ListTile(
                title: Text(
                  label(
                    'No messages waiting for review.',
                    'لا توجد رسائل بانتظار المراجعة.',
                  ),
                ),
              );
            }
            return Column(
              children: [
                for (final event in snapshot.data!)
                  ListTile(
                    title: Text(_amountLabel(event)),
                    subtitle: Text(event['raw_text'] as String),
                    onTap: _busy ? null : () => _review(event),
                    trailing: IconButton(
                      tooltip: label('Ignore message', 'تجاهل الرسالة'),
                      icon: const Icon(Icons.close),
                      onPressed: _busy
                          ? null
                          : () => _run(
                              () => database.setImportedFinancialEventStatus(
                                event['event_pk'] as String,
                                'ignored',
                              ),
                            ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
