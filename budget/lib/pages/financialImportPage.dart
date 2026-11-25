import 'package:budget/widgets/cashuSurfaces.dart';
import 'package:budget/struct/bankMessageBatch.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/widgets/openPopup.dart' show RoutesToPopAfterDelete;
import 'package:budget/struct/bankNotificationInbox.dart';
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
  static const _pageSize = 30;
  String _status = 'review';
  String? _direction;
  String? _source;
  int _offset = 0;
  late var _imports = _loadImports();

  Future<List<Map<String, dynamic>>> _loadImports() =>
      database.getImportedFinancialEvents(
        status: _status,
        direction: _direction,
        sourceType: _source,
        limit: _pageSize + 1,
        offset: _offset,
      );

  void _reloadFirstPage() {
    _offset = 0;
    _imports = _loadImports();
  }

  bool _busy = false;
  DateTime? _occurredAt;

  String label(String english, String arabic) =>
      FinancialImportPage.label(context, english, arabic);

  @override
  void initState() {
    super.initState();
    bankNotificationInbox.revision.addListener(_refreshInbox);
  }

  void _refreshInbox() {
    if (mounted) setState(_reloadFirstPage);
  }

  @override
  void dispose() {
    bankNotificationInbox.revision.removeListener(_refreshInbox);
    _message.dispose();
    super.dispose();
  }

  void _notify(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) setState(_reloadFirstPage);
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

  Future<bool> _queueMessage(
          String raw, ParsedFinancialMessage parsed, DateTime occurredAt) =>
      database.stageImportedFinancialEvent(
        eventPk: uuid.v4(),
        sourceType: 'manual',
        rawText: raw,
        occurredAt: occurredAt,
        amount: parsed.amount,
        currency: parsed.currency,
        direction: parsed.direction,
        merchant: parsed.merchant,
        identifierLast4: parsed.lastFour,
        confidence: parsed.confidence,
      );

  Future<void> _stage() => _run(() async {
        final raw = _message.text.trim();
        if (raw.length > maxBankMessageLength) {
          _notify(label('Use batch review for multiple messages.',
              'استخدم مراجعة الدفعة لو عندك أكتر من رسالة.'));
          return;
        }
        final parsed = FinancialMessageParser.parse(raw);
        if (!canStageBankMessage(parsed)) {
          _notify(
            label(
              'Enter a message with one amount, its currency, and a transaction type.',
              'أدخل رسالة تحتوي على مبلغ واحد وعملته ونوع المعاملة.',
            ),
          );
          return;
        }
        final queued =
            await _queueMessage(raw, parsed, _occurredAt ?? DateTime.now());
        if (!mounted) return;
        if (!queued) {
          _notify(label('This message has already been imported.',
              'تم استيراد هذه الرسالة بالفعل.'));
          return;
        }
        _message.clear();
        setState(() => _occurredAt = null);
      });

  Future<void> _stageBatch() => _run(() async {
        final List<BankMessageLine> rows;
        try {
          rows = parseBankMessageBatch(_message.text);
        } on FormatException {
          _notify(label('Paste between 1 and 25 messages, one per line.',
              'الصق من رسالة إلى ٢٥ رسالة، كل رسالة في سطر.'));
          return;
        }
        final eligible =
            rows.where((row) => canStageBankMessage(row.parsed)).toList();
        final selectedTime = _occurredAt ?? DateTime.now();
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            scrollable: true,
            title:
                Text(label('Review batch import', 'مراجعة الاستيراد الجماعي')),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(label('All messages use the selected date and time.',
                  'كل الرسائل هتستخدم التاريخ والوقت المحددين.')),
              Text(_formatTimestamp(selectedTime)),
              for (final row in rows)
                ListTile(
                  title: Text(label('Line ${row.line}', 'السطر ${row.line}')),
                  subtitle: Text(eligible.contains(row)
                      ? _amountLabel({
                          'direction': row.parsed.direction,
                          'amount': row.parsed.amount,
                          'currency': row.parsed.currency,
                        })
                      : label(
                          'Could not read this message. It will be skipped.',
                          'تعذّرت قراءة الرسالة وسيتم تخطيها.')),
                ),
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(label('Cancel', 'إلغاء'))),
              FilledButton(
                onPressed: eligible.isEmpty
                    ? null
                    : () => Navigator.pop(context, true),
                child: Text(label('Queue ${eligible.length} for review',
                    'إضافة ${eligible.length} للمراجعة')),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        var added = 0;
        await database.transaction(() async {
          for (final row in eligible) {
            final queued =
                await _queueMessage(row.raw, row.parsed, selectedTime);
            if (queued) added++;
          }
        });
        if (!mounted) return;
        final skipped = eligible.length - added;
        _notify(label('$added queued. $skipped already imported.',
            'تمت إضافة $added للمراجعة. $skipped مستوردة مسبقًا.'));
        if (eligible.length == rows.length) {
          _message.clear();
          setState(() => _occurredAt = null);
        } else {
          _message.text = rows
              .where((row) => !eligible.contains(row))
              .map((row) => row.raw)
              .join('\n');
        }
      });

  Future<void> _review(Map<String, dynamic> event) => _run(() async {
        final archived = await database.getAllAccountDetails();
        final wallets = (await database.getAllWallets())
            .where((wallet) =>
                wallet.currency?.toLowerCase() == event['currency'] &&
                archived[wallet.walletPk]?['archived'] != 1)
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
        final lastFour = event['identifier_last4'] as String?;
        final currency = event['currency'] as String?;
        final suggestedWallet =
            lastFour == null && event['source_type'] == 'notification'
                ? await database.suggestImportedNotificationWallet(
                    event['source_sender'] as String?, currency)
                : await database.suggestImportedCardWallet(lastFour, currency);
        if (!mounted) return;
        String? walletPk =
            wallets.any((wallet) => wallet.walletPk == suggestedWallet)
                ? suggestedWallet
                : null;
        String? categoryPk;
        final initialTitle = String.fromCharCodes(
          ((event['merchant'] as String?) ?? '').runes.take(NAME_LIMIT),
        );
        var title = initialTitle;
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
                    Text(lastFour != null
                        ? label('Account suggested from card digits.',
                            'تم اقتراح الحساب بناءً على آخر أربعة أرقام من البطاقة.')
                        : label('Account suggested from the notification app.',
                            'تم اقتراح الحساب بناءً على تطبيق الإشعار.')),
                  TextFormField(
                    initialValue: initialTitle,
                    maxLength: NAME_LIMIT,
                    onChanged: (value) => title = value,
                    decoration:
                        InputDecoration(labelText: label('Title', 'العنوان')),
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
                  if (lastFour != null &&
                      walletPk != null &&
                      suggestedWallet == null)
                    TextButton.icon(
                      icon: const Icon(Icons.link),
                      label: Text(label('Link card to this account',
                          'ربط البطاقة بهذا الحساب')),
                      onPressed: () => showDialog<void>(
                        context: dialogContext,
                        builder: (_) => ImportCardLinks(
                          initialWalletPk: walletPk,
                          initialDigits: lastFour,
                        ),
                      ),
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
        final transactionPk = uuid.v4();
        Future<String> save(ImportDuplicateAction action,
                {String? expectedExistingPk}) =>
            database.approveImportedFinancialEvent(
              eventPk: event['event_pk'] as String,
              transactionPk: transactionPk,
              categoryFk: categoryPk!,
              walletPk: walletPk,
              title: title.trim().isEmpty
                  ? label('Imported transaction', 'معاملة مستوردة')
                  : String.fromCharCodes(title.runes.take(NAME_LIMIT)),
              duplicateAction: action,
              expectedExistingPk: expectedExistingPk,
            );
        String result;
        try {
          result = await save(ImportDuplicateAction.ask);
        } on ImportedTransactionMatch catch (match) {
          if (!mounted) return;
          final existing = match.transaction;
          final choice = await showDialog<ImportDuplicateAction>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(label('Possible duplicate', 'معاملة محتمل تكرارها')),
              content: Text([
                label(
                    'A paid transaction with this amount is already recorded around this time.',
                    'توجد معاملة مدفوعة بنفس المبلغ في وقت قريب.'),
                existing.name,
                _formatTimestamp(existing.dateCreated),
              ].join('\n')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(label('Cancel', 'إلغاء'))),
                TextButton(
                  onPressed: () => Navigator.pop(
                      context, ImportDuplicateAction.linkExisting),
                  child:
                      Text(label('Use existing', 'استخدم المعاملة الموجودة')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(
                      context, ImportDuplicateAction.saveSeparate),
                  child: Text(label('Save separately', 'احفظ كمعاملة منفصلة')),
                ),
              ],
            ),
          );
          if (choice == null || !mounted) return;
          result = await save(choice,
              expectedExistingPk: choice == ImportDuplicateAction.linkExisting
                  ? existing.transactionPk
                  : null);
        }
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

  Future<void> _openLinkedTransaction(String id) async {
    Transaction transaction;
    try {
      transaction = await database.getTransactionFromPk(id);
    } catch (_) {
      if (mounted) {
        _notify(label('The linked transaction is unavailable.',
            'المعاملة المرتبطة غير متاحة.'));
      }
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AddTransactionPage(
        transaction: transaction,
        routesToPopAfterDelete: RoutesToPopAfterDelete.None,
      ),
    ));
  }

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
      title: label('Bank messages', 'الرسائل البنكية'),
      backgroundColor: CashuColors(context).canvas,
      horizontalPaddingConstrained: true,
      capitalizeTitle: false,
      listWidgets: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CashuOptionSection(
                icon: Icons.content_paste_rounded,
                title: label('Paste a bank message', 'الصق رسالة بنكية'),
                detail: label('Review a single message or a batch',
                    'راجع رسالة واحدة أو دفعة رسائل'),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: TextField(
                      controller: _message,
                      minLines: 2,
                      maxLines: 4,
                      maxLength: maxBankBatchLength,
                      decoration: cashuInput(
                        context,
                        label('Paste a transaction message',
                            'الصق رسالة المعاملة'),
                      ),
                    ),
                  ),
                  ListTile(
                    leading: const CashuIconTile(Icons.calendar_today_outlined,
                        size: 36),
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
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    FilledButton(
                      onPressed: _busy ? null : _stage,
                      child: Text(label('Add for review', 'إضافة للمراجعة')),
                    ),
                    OutlinedButton(
                      onPressed: _busy ? null : _stageBatch,
                      child: Text(label('Review batch', 'مراجعة دفعة')),
                    ),
                  ]),
                ],
              ),
              const SizedBox(height: 9),
              CashuOptionSection(
                icon: Icons.link_outlined,
                title: label('Cards and notifications', 'البطاقات والإشعارات'),
                children: [
                  CashuActionRow(
                    icon: Icons.credit_card_outlined,
                    title: label('Manage card links', 'إدارة ربط البطاقات'),
                    onTap: _busy
                        ? null
                        : () => showDialog<void>(
                              context: context,
                              builder: (_) => const ImportCardLinks(),
                            ),
                  ),
                  if (BankNotificationInbox.supported) ...[
                    CashuActionRow(
                      icon: Icons.link_outlined,
                      title: label('Link notification apps to accounts',
                          'ربط تطبيقات الإشعارات بالحسابات'),
                      onTap: _busy
                          ? null
                          : () => showDialog<void>(
                                context: context,
                                builder: (_) =>
                                    const _ImportNotificationLinks(),
                              ),
                    ),
                    CashuActionRow(
                      icon: Icons.notifications_outlined,
                      title: label('Android notification import',
                          'استيراد إشعارات أندرويد'),
                      onTap: _busy
                          ? null
                          : () => showDialog<void>(
                                context: context,
                                builder: (_) =>
                                    const _BankNotificationSettings(),
                              ),
                    ),
                  ],
                ],
              ),
              CashuSectionTitle(label('Message inbox', 'صندوق الرسائل')),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final (status, text) in [
                  ('review', label('Needs review', 'بانتظار المراجعة')),
                  ('approved', label('Approved', 'تم الاعتماد')),
                  ('ignored', label('Ignored', 'تم التجاهل')),
                  ('duplicate', label('Duplicates', 'المكررات')),
                ])
                  ChoiceChip(
                    label: Text(text),
                    selected: status == _status,
                    onSelected: _busy
                        ? null
                        : (_) => setState(() {
                              _status = status;
                              _reloadFirstPage();
                            }),
                  ),
              ]),
              const SizedBox(height: 8),
              CashuOptionSection(
                icon: Icons.filter_alt_outlined,
                title: label('Filters', 'الفلاتر'),
                initiallyExpanded: _source != null || _direction != null,
                children: [
                  DropdownButton<String>(
                    isExpanded: true,
                    value: _source ?? '',
                    items: [
                      DropdownMenuItem(
                          value: '',
                          child: Text(label('All sources', 'كل المصادر'))),
                      DropdownMenuItem(
                          value: 'manual',
                          child: Text(
                              label('Pasted messages', 'الرسائل الملصوقة'))),
                      DropdownMenuItem(
                          value: 'notification',
                          child: Text(label(
                              'Android notifications', 'إشعارات أندرويد'))),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) => setState(() {
                              _source = value == '' ? null : value;
                              _reloadFirstPage();
                            }),
                  ),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: _direction ?? '',
                    items: [
                      DropdownMenuItem(
                          value: '',
                          child: Text(label(
                              'All transaction types', 'كل أنواع المعاملات'))),
                      DropdownMenuItem(
                          value: 'debit',
                          child: Text(label('Money out', 'مبالغ خارجة'))),
                      DropdownMenuItem(
                          value: 'credit',
                          child: Text(label('Money in', 'مبالغ واردة'))),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) => setState(() {
                              _direction = value == '' ? null : value;
                              _reloadFirstPage();
                            }),
                  ),
                ],
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
            if (snapshot.connectionState != ConnectionState.done) {
              return const LinearProgressIndicator();
            }
            final events = snapshot.data!;
            if (events.isEmpty && _offset == 0) {
              return ListTile(
                title: Text(
                  label(
                    'No matching imports.',
                    'لا توجد عمليات استيراد مطابقة.',
                  ),
                ),
              );
            }
            return Column(
              children: [
                for (final event in events.take(_pageSize))
                  ListTile(
                    title: Text(_amountLabel(event)),
                    subtitle: Text([
                      _formatTimestamp(DateTime.fromMillisecondsSinceEpoch(
                          event['occurred_at'] as int)),
                      if (event['source_type'] == 'notification')
                        '${label('Android notification', 'إشعار أندرويد')} · ${event['source_sender']}'
                      else if (event['raw_text'] case final String text
                          when text.isNotEmpty)
                        text,
                    ].join('\n')),
                    onTap: _busy
                        ? null
                        : _status == 'review'
                            ? () => _review(event)
                            : event['transaction_fk'] is String
                                ? () => _openLinkedTransaction(
                                    event['transaction_fk'] as String)
                                : null,
                    trailing: switch (_status) {
                      'review' => IconButton(
                          tooltip: label('Ignore message', 'تجاهل الرسالة'),
                          icon: const Icon(Icons.close),
                          onPressed: _busy
                              ? null
                              : () => _run(
                                    () => database
                                        .setImportedFinancialEventStatus(
                                      event['event_pk'] as String,
                                      'ignored',
                                    ),
                                  ),
                        ),
                      'ignored' => IconButton(
                          tooltip: label('Return to review', 'إعادة للمراجعة'),
                          icon: const Icon(Icons.undo),
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                    await database.restoreIgnoredFinancialEvent(
                                        event['event_pk'] as String);
                                  }),
                        ),
                      _ => event['transaction_fk'] == null
                          ? null
                          : const Icon(Icons.chevron_right),
                    },
                  ),
                if (_offset > 0 || events.length > _pageSize)
                  Wrap(children: [
                    TextButton(
                      onPressed: _offset == 0
                          ? null
                          : () => setState(() {
                                _offset -= _pageSize;
                                _imports = _loadImports();
                              }),
                      child: Text(label('Newer', 'الأحدث')),
                    ),
                    TextButton(
                      onPressed: events.length <= _pageSize
                          ? null
                          : () => setState(() {
                                _offset += _pageSize;
                                _imports = _loadImports();
                              }),
                      child: Text(label('Older', 'الأقدم')),
                    ),
                  ]),
              ],
            );
          },
        ),
      ],
    );
  }
}

class ImportCardLinks extends StatefulWidget {
  const ImportCardLinks({super.key, this.initialWalletPk, this.initialDigits});

  final String? initialWalletPk;
  final String? initialDigits;

  @override
  State<ImportCardLinks> createState() => _ImportCardLinksState();
}

class _ImportCardLinksState extends State<ImportCardLinks> {
  late final _digits = TextEditingController(text: widget.initialDigits);
  late final _wallets = database.getFinancialInsightsAccounts().then(
        (accounts) =>
            accounts.where((account) => account.currency.isNotEmpty).toList(),
      );
  late var _links = database.getImportCardLinks();
  late String? _wallet = widget.initialWalletPk;
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
            Text(_label(
              'CashU uses the last four digits and currency to suggest an account in Bank Messages.',
              'يقترح CashU الحساب في الرسائل البنكية باستخدام آخر أربعة أرقام والعملة.',
            )),
            FutureBuilder(
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
                  value: snapshot.data!.any((account) => account.id == _wallet)
                      ? _wallet
                      : null,
                  items: [
                    for (final account in snapshot.data!)
                      DropdownMenuItem(
                          value: account.id,
                          child: Text(
                              '${account.name} · ${account.currency.toUpperCase()}',
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

class _ImportNotificationLinks extends StatefulWidget {
  const _ImportNotificationLinks();

  @override
  State<_ImportNotificationLinks> createState() =>
      _ImportNotificationLinksState();
}

class _ImportNotificationLinksState extends State<_ImportNotificationLinks> {
  late final _accounts = database.getFinancialInsightsAccounts();
  late var _links = database.getImportNotificationLinks();
  final _packages = bankNotificationInbox.packages;
  String? _package;
  String? _account;
  String? _message;
  bool _busy = false;

  String _label(String en, String ar) =>
      FinancialImportPage.label(context, en, ar);

  Future<void> _change({String? remove}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (remove != null) {
        await database.removeImportNotificationLink(remove);
      } else if (!await database.addImportNotificationLink(
          _account!, _package!)) {
        if (mounted)
          _message = _label('This app already has a link for this currency.',
              'هذا التطبيق مرتبط بالفعل بحساب بهذه العملة.');
      }
      if (mounted) _links = database.getImportNotificationLinks();
    } catch (_) {
      if (mounted)
        _message = _label('Could not update links.', 'تعذّر تحديث الربط.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        scrollable: true,
        title: Text(
            _label('Notification account links', 'ربط الإشعارات بالحسابات')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_packages.isEmpty)
            Text(_label('Choose apps in Android notification import first.',
                'اختر التطبيقات من إعدادات استيراد إشعارات أندرويد أولًا.'))
          else
            DropdownButton<String>(
              isExpanded: true,
              hint: Text(_label('Notification app', 'تطبيق الإشعارات')),
              value: _package,
              items: [
                for (final name in _packages)
                  DropdownMenuItem(
                    value: name,
                    child: Text(name, overflow: TextOverflow.ellipsis),
                  )
              ],
              onChanged:
                  _busy ? null : (value) => setState(() => _package = value),
            ),
          FutureBuilder(
            future: _accounts,
            builder: (context, snapshot) {
              if (snapshot.hasError)
                return Text(_label(
                    'Could not load accounts.', 'تعذّر تحميل الحسابات.'));
              if (!snapshot.hasData) return const LinearProgressIndicator();
              return DropdownButton<String>(
                isExpanded: true,
                hint: Text(_label('Account', 'الحساب')),
                value: _account,
                items: [
                  for (final account in snapshot.data!)
                    if (account.currency.isNotEmpty)
                      DropdownMenuItem(
                        value: account.id,
                        child: Text(
                            '${account.name} · ${account.currency.toUpperCase()}',
                            overflow: TextOverflow.ellipsis),
                      ),
                ],
                onChanged:
                    _busy ? null : (value) => setState(() => _account = value),
              );
            },
          ),
          if (_message != null) Text(_message!),
          OutlinedButton(
            onPressed: _busy || _account == null || _package == null
                ? null
                : () => _change(),
            child: Text(_label('Link app', 'ربط التطبيق')),
          ),
          FutureBuilder(
            future: _links,
            builder: (context, snapshot) {
              if (snapshot.hasError)
                return Text(
                    _label('Could not load links.', 'تعذّر تحميل الربط.'));
              if (!snapshot.hasData) return const LinearProgressIndicator();
              return Column(children: [
                for (final link in snapshot.data!)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                        '${link.account} · ${link.currency.toUpperCase()}'),
                    subtitle: Text(link.package),
                    trailing: IconButton(
                      tooltip: _label('Remove link', 'إزالة الربط'),
                      icon: const Icon(Icons.link_off),
                      onPressed: _busy ? null : () => _change(remove: link.id),
                    ),
                  ),
              ]);
            },
          ),
        ]),
        actions: [
          TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: Text(_label('Done', 'تم'))),
        ],
      );
}

class _BankNotificationSettings extends StatefulWidget {
  const _BankNotificationSettings();

  @override
  State<_BankNotificationSettings> createState() =>
      _BankNotificationSettingsState();
}

class _BankNotificationSettingsState extends State<_BankNotificationSettings> {
  late final _packages =
      TextEditingController(text: bankNotificationInbox.packages.join('\n'));
  late bool _enabled = bankNotificationInbox.enabled;
  late bool _background = bankNotificationInbox.backgroundEnabled;
  bool _busy = false;
  String? _error;

  String _label(String english, String arabic) =>
      FinancialImportPage.label(context, english, arabic);

  @override
  void dispose() {
    _packages.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final packages = BankNotificationInbox.parsePackages(_packages.text);
      if (_enabled && packages.isEmpty) throw const FormatException();
      if (_enabled && !await bankNotificationInbox.hasAccess()) {
        if (mounted)
          setState(() => _error = _label(
                'Allow notification access in Android settings.',
                'اسمح بالوصول إلى الإشعارات من إعدادات أندرويد.',
              ));
        return;
      }
      if (!mounted) return;
      await bankNotificationInbox.configure(
          enabled: _enabled, packages: packages, background: _background);
      if (mounted) Navigator.pop(context);
    } on FormatException {
      if (mounted)
        setState(() => _error = _label(
              'Enter up to 20 valid Android app package names.',
              'أدخل أسماء حزم صالحة لما يصل إلى ٢٠ تطبيقًا.',
            ));
    } catch (_) {
      if (mounted)
        setState(() => _error = _label(
              'Could not save notification import settings.',
              'تعذّر حفظ إعدادات استيراد الإشعارات.',
            ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseApp() async {
    setState(() => _busy = true);
    try {
      final apps = await bankNotificationInbox.listApps();
      if (!mounted) return;
      final selected = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(_label('Choose an installed app', 'اختر تطبيقًا مثبتًا')),
          children: [
            if (apps.isEmpty) const SizedBox(height: 16),
            for (final app in apps)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, app.package),
                child: Text('${app.label}\n${app.package}'),
              ),
          ],
        ),
      );
      if (selected == null || !mounted) return;
      final packages =
          BankNotificationInbox.parsePackages('${_packages.text} $selected');
      _packages.text = packages.join('\n');
    } catch (_) {
      if (mounted)
        setState(() => _error = _label(
              'Could not add the app. Check the package list.',
              'تعذّرت إضافة التطبيق. تحقّق من قائمة الحزم.',
            ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openAccessSettings() async {
    try {
      await bankNotificationInbox.openAccessSettings();
    } catch (_) {
      if (mounted)
        setState(() => _error = _label(
              'Could not open Android notification access settings.',
              'تعذّر فتح إعدادات الوصول إلى الإشعارات.',
            ));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(
            _label('Android notification import', 'استيراد إشعارات أندرويد')),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_label(
              'Matching notifications from selected apps appear for review. Cashew can also read recent alerts that are still visible when you reopen it.',
              'تظهر الإشعارات المطابقة من التطبيقات المحددة للمراجعة. يمكن لـ Cashew أيضًا قراءة التنبيهات الحديثة التي ما زالت ظاهرة عند فتحه مجددًا.',
            )),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_label('Import from selected apps',
                  'الاستيراد من التطبيقات المحددة')),
              value: _enabled,
              onChanged:
                  _busy ? null : (value) => setState(() => _enabled = value),
            ),
            if (_enabled)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_label('Capture while Cashew is closed',
                    'الالتقاط أثناء إغلاق Cashew')),
                subtitle: Text(_label(
                  'Android can retain up to 100 matching alerts in encrypted storage for up to 24 hours. The pending text is cleared after review staging or when capture is disabled.',
                  'يمكن لأندرويد الاحتفاظ بما يصل إلى ١٠٠ تنبيه مطابق مشفّرًا ولمدة تصل إلى ٢٤ ساعة. يُحذف النص بعد إرساله للمراجعة أو تعطيل الالتقاط.',
                )),
                value: _background,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _background = value),
              ),
            TextField(
              controller: _packages,
              enabled: !_busy,
              minLines: 2,
              maxLines: 5,
              autocorrect: false,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                labelText: _label('App package names', 'أسماء حزم التطبيقات'),
                helperText: _label(
                    'One package per line. Find it after id= in the Play Store link.',
                    'حزمة واحدة لكل سطر. تجد الاسم بعد id= في رابط متجر Play.'),
                helperMaxLines: 3,
              ),
            ),
            OutlinedButton(
              onPressed: _busy ? null : _chooseApp,
              child:
                  Text(_label('Choose installed app', 'اختر تطبيقًا مثبتًا')),
            ),
            if (_enabled)
              OutlinedButton(
                onPressed: _busy ? null : _openAccessSettings,
                child: Text(_label('Open Android notification access',
                    'فتح إعدادات الوصول إلى الإشعارات')),
              ),
            if (_error != null) Text(_error!),
          ],
        ),
        actions: [
          TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: Text(_label('Cancel', 'إلغاء'))),
          FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_label('Save', 'حفظ'))),
        ],
      );
}
