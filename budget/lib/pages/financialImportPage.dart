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
  DateTime? _occurredAt;

  String label(String english, String arabic) =>
      FinancialImportPage.label(context, english, arabic);

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  void _notify(String message) => ScaffoldMessenger.of(context)
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

  String _formatTimestamp(DateTime value) {
    final localizations = MaterialLocalizations.of(context);
    return '${localizations.formatMediumDate(value)} · '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(value))}';
  }

  Future<void> _pickTimestamp() async {
    final now = DateTime.now();
    final initial = _occurredAt ?? now;
    final day = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1900),
      lastDate: now,
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted) return;
    final timestamp =
        DateTime(day.year, day.month, day.day, time.hour, time.minute);
    if (timestamp.isAfter(DateTime.now())) {
      _notify(label(
          'Choose a time that has already passed.', 'اختر وقتًا قد مضى.'));
      return;
    }
    setState(() => _occurredAt = timestamp);
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
        final queued = await database.stageImportedFinancialEvent(
          eventPk: uuid.v4(),
          sourceType: 'manual',
          rawText: raw,
          occurredAt: _occurredAt ?? DateTime.now(),
          amount: parsed.amount,
          currency: parsed.currency,
          direction: parsed.direction,
          merchant: parsed.merchant,
          identifierLast4: parsed.lastFour,
          confidence: parsed.confidence,
        );
        if (!mounted) return;
        if (!queued) {
          _notify(label('This message has already been imported.',
              'تم استيراد هذه الرسالة بالفعل.'));
          return;
        }
        _message.clear();
        setState(() => _occurredAt = null);
      });

  Future<void> _review(Map<String, dynamic> event) => _run(() async {
        final wallets = (await database.getAllWallets())
            .where(
                (wallet) => wallet.currency?.toLowerCase() == event['currency'])
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
        final suggestedWallet = await database.suggestImportedCardWallet(
          event['identifier_last4'] as String?,
          event['currency'] as String?,
        );
        if (!mounted) return;
        String? walletPk =
            wallets.any((wallet) => wallet.walletPk == suggestedWallet)
                ? suggestedWallet
                : null;
        String? categoryPk;
        final approved = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
              title: Text(label('Approve transaction', 'اعتماد المعاملة')),
              scrollable: true,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_amountLabel(event)),
                  Text(_formatTimestamp(DateTime.fromMillisecondsSinceEpoch(
                    event['occurred_at'] as int,
                  ))),
                  if (suggestedWallet != null && walletPk == suggestedWallet)
                    Text(label('Account suggested from card digits.',
                        'تم اقتراح الحساب بناءً على آخر أربعة أرقام من البطاقة.')),
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
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => showDialog<void>(
                          context: context,
                          builder: (_) => const _ImportCardLinks(),
                        ),
                child: Text(label('Manage card links', 'إدارة ربط البطاقات')),
              ),
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
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.calendar_today_outlined),
                title: Text(label(
                    'Transaction date and time', 'تاريخ المعاملة ووقتها')),
                subtitle: Text(_occurredAt == null
                    ? label('Use the current time', 'استخدم الوقت الحالي')
                    : _formatTimestamp(_occurredAt!)),
                onTap: _busy ? null : _pickTimestamp,
                trailing: _occurredAt == null
                    ? null
                    : IconButton(
                        tooltip: label(
                            'Use the current time', 'استخدم الوقت الحالي'),
                        onPressed: _busy
                            ? null
                            : () => setState(() => _occurredAt = null),
                        icon: const Icon(Icons.clear),
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

class _ImportCardLinks extends StatefulWidget {
  const _ImportCardLinks();

  @override
  State<_ImportCardLinks> createState() => _ImportCardLinksState();
}

class _ImportCardLinksState extends State<_ImportCardLinks> {
  final _digits = TextEditingController();
  late final _wallets = database.getAllWallets();
  late var _links = database.getImportCardLinks();
  String? _wallet;
  String? _error;
  bool _busy = false;

  String _label(String english, String arabic) =>
      FinancialImportPage.label(context, english, arabic);

  @override
  void dispose() {
    _digits.dispose();
    super.dispose();
  }

  Future<void> _change({String? removeId}) async {
    if (_busy) return;
    final digits = FinancialMessageParser.normalize(_digits.text.trim());
    if (removeId == null &&
        (_wallet == null || !RegExp(r'^[0-9]{4}$').hasMatch(digits))) {
      setState(() => _error = _label('Select an account and enter four digits.',
          'اختر حسابًا وأدخل أربعة أرقام.'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (removeId != null) {
        await database.removeImportCardLink(removeId);
      } else if (!await database.addImportCardLink(_wallet!, digits)) {
        if (mounted)
          setState(() => _error = _label(
                'These digits are already linked. Remove that link before reassigning them.',
                'هذه الأرقام مرتبطة بالفعل. احذف الربط الحالي قبل إعادة تعيينها.',
              ));
        return;
      } else if (mounted) {
        _digits.clear();
      }
      if (mounted) setState(() => _links = database.getImportCardLinks());
    } catch (_) {
      if (mounted)
        setState(() => _error = _label(
              'Could not update card links.',
              'تعذّر تحديث ربط البطاقات.',
            ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        scrollable: true,
        title: Text(_label('Manage card links', 'إدارة ربط البطاقات')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FutureBuilder<List<TransactionWallet>>(
              future: _wallets,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Text(_label(
                      'Could not load accounts.', 'تعذّر تحميل الحسابات.'));
                }
                if (!snapshot.hasData) return const LinearProgressIndicator();
                return DropdownButton<String>(
                  isExpanded: true,
                  hint: Text(_label('Account', 'الحساب')),
                  value: _wallet,
                  items: [
                    for (final wallet in snapshot.data!)
                      DropdownMenuItem(
                          value: wallet.walletPk,
                          child: Text(wallet.name,
                              overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged:
                      _busy ? null : (value) => setState(() => _wallet = value),
                );
              },
            ),
            TextField(
              controller: _digits,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              maxLength: 4,
              decoration: InputDecoration(
                  labelText: _label(
                      'Last four card digits', 'آخر أربعة أرقام من البطاقة')),
            ),
            if (_error != null) Text(_error!),
            OutlinedButton(
              onPressed: _busy ? null : () => _change(),
              child: Text(_label('Link card', 'ربط البطاقة')),
            ),
            FutureBuilder(
              future: _links,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Text(_label('Could not load card links.',
                      'تعذّر تحميل ربط البطاقات.'));
                }
                if (!snapshot.hasData) return const LinearProgressIndicator();
                return Column(children: [
                  for (final link in snapshot.data!)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(link.account),
                      subtitle: Text(link.digits),
                      trailing: IconButton(
                        tooltip:
                            _label('Remove card link', 'إزالة ربط البطاقة'),
                        icon: const Icon(Icons.link_off),
                        onPressed:
                            _busy ? null : () => _change(removeId: link.id),
                      ),
                    ),
                ]);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(_label('Done', 'تم')),
          ),
        ],
      );
}
