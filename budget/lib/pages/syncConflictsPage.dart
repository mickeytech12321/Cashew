import 'dart:convert';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:flutter/material.dart';

class SyncConflictsPage extends StatefulWidget {
  const SyncConflictsPage({super.key});

  @override
  State<SyncConflictsPage> createState() => _SyncConflictsPageState();
}

class _SyncConflictsPageState extends State<SyncConflictsPage> {
  late var _conflicts = database.getOpenSyncConflicts();
  bool _busy = false;

  String _label(String en, String ar) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;

  Widget _version(Transaction transaction, String heading, String? account,
      String? category) {
    final date = MaterialLocalizations.of(context)
        .formatMediumDate(transaction.dateCreated);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(heading),
      subtitle: Text([
        transaction.name,
        if (account != null) account,
        if (category != null) category,
        if (transaction.note.trim().isNotEmpty) transaction.note,
        date,
        _label(transaction.paid ? 'Paid' : 'Unpaid',
            transaction.paid ? 'مدفوع' : 'غير مدفوع'),
      ].join('\n')),
      trailing: Text(transaction.amount.toString()),
    );
  }

  String _metadataTitle(String type) => switch (type) {
        'TransactionWallet' => _label('Account', 'حساب'),
        'TransactionCategory' => _label('Category', 'تصنيف'),
        'Budget' => _label('Budget', 'ميزانية'),
        'CategoryBudgetLimit' =>
          _label('Category budget limit', 'حد ميزانية التصنيف'),
        'TransactionAssociatedTitle' => _label('Saved title', 'عنوان محفوظ'),
        'ScannerTemplate' => _label('Scanner template', 'قالب المسح'),
        'Objective' => _label('Goal or loan', 'هدف أو قرض'),
        _ => _label('Record', 'سجل'),
      };

  Future<void> _reviewMetadata(Map<String, dynamic> conflict) async {
    final before =
        jsonDecode(conflict['local_json'] as String) as Map<String, dynamic>;
    final after =
        jsonDecode(conflict['remote_json'] as String) as Map<String, dynamic>;
    final local = before['fields'] as Map<String, dynamic>;
    final remote = after['fields'] as Map<String, dynamic>?;
    final labels = {
      'name': _label('Name', 'الاسم'),
      'title': _label('Title', 'العنوان'),
      'templateName': _label('Template name', 'اسم القالب'),
      'amount': _label('Amount', 'المبلغ'),
      'currency': _label('Currency', 'العملة'),
      'currencyFormat': _label('Currency format', 'تنسيق العملة'),
      'decimals': _label('Decimal places', 'الخانات العشرية'),
      'income': _label('Income', 'دخل'),
      'archived': _label('Archived', 'مؤرشف'),
      'pinned': _label('Pinned', 'مثبت'),
      'ignore': _label('Ignore matches', 'تجاهل المطابقات'),
      'isExactMatch': _label('Exact match', 'مطابقة تامة'),
      'contains': _label('Matches text', 'النص المطابق'),
      'dateCreated': _label('Created', 'تاريخ الإنشاء'),
      'startDate': _label('Start date', 'تاريخ البداية'),
      'endDate': _label('End date', 'تاريخ النهاية'),
      'walletFk': _label('Account', 'الحساب'),
      'walletFks': _label('Accounts', 'الحسابات'),
      'categoryFk': _label('Category', 'التصنيف'),
      'mainCategoryPk': _label('Parent category', 'التصنيف الرئيسي'),
      'defaultCategoryFk': _label('Default category', 'التصنيف الافتراضي'),
      'categoryFks': _label('Included categories', 'التصنيفات المضمّنة'),
      'categoryFksExclude':
          _label('Excluded categories', 'التصنيفات المستبعدة'),
      'budgetFk': _label('Budget', 'الميزانية'),
      'periodLength': _label('Repeat interval', 'مدة التكرار'),
      'reoccurrence': _label('Repeat frequency', 'وتيرة التكرار'),
      'order': _label('Display order', 'ترتيب العرض'),
      'colour': _label('Color', 'اللون'),
      'iconName': _label('Icon', 'الأيقونة'),
      'emojiIconName': _label('Emoji', 'الرمز التعبيري'),
      'titleTransactionBefore': _label('Text before title', 'النص قبل العنوان'),
      'titleTransactionAfter': _label('Text after title', 'النص بعد العنوان'),
      'amountTransactionBefore':
          _label('Text before amount', 'النص قبل المبلغ'),
      'amountTransactionAfter': _label('Text after amount', 'النص بعد المبلغ'),
      'addedTransactionsOnly':
          _label('Only assigned transactions', 'المعاملات المعيّنة فقط'),
      'isAbsoluteSpendingLimit':
          _label('Absolute spending limit', 'حد الإنفاق المطلق'),
      'type': _label('Record type', 'نوع السجل'),
    };
    final changes = <String>[
      if (remote != null)
        for (final key in local.keys.toSet().union(remote.keys.toSet()))
          if (key != 'dateTimeModified' &&
              jsonEncode(local[key]) != jsonEncode(remote[key]))
            key,
    ];
    final accounts =
        changes.any((key) => key == 'walletFk' || key == 'walletFks')
            ? {
                for (final row in await database.getAllWallets())
                  row.walletPk: row.name
              }
            : const <String, String>{};
    const categoryFields = {
      'categoryFk',
      'mainCategoryPk',
      'defaultCategoryFk',
      'categoryFks',
      'categoryFksExclude'
    };
    final categories = changes.any(categoryFields.contains)
        ? {
            for (final row
                in await database.getAllCategories(includeSubCategories: true))
              row.categoryPk: row.name
          }
        : const <String, String>{};
    if (!mounted) return;
    final dates = MaterialLocalizations.of(context);
    String value(String key, Object? data) {
      if (const {'dateCreated', 'startDate', 'endDate', 'sharedDateUpdated'}
          .contains(key)) {
        final date = switch (data) {
          int time => DateTime.fromMillisecondsSinceEpoch(time),
          String time => DateTime.tryParse(time),
          _ => null,
        };
        if (date != null) return dates.formatMediumDate(date);
      }
      final names = key == 'walletFk' || key == 'walletFks'
          ? accounts
          : categoryFields.contains(key)
              ? categories
              : const <String, String>{};
      return switch (data) {
        true => _label('Yes', 'نعم'),
        false => _label('No', 'لا'),
        null => '—',
        String id => names[id] ?? id,
        List values =>
          values.map((id) => names[id] ?? id.toString()).join(', '),
        _ => data.toString(),
      };
    }

    final name = local['name'] ?? local['title'] ?? local['templateName'];
    final result = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        scrollable: true,
        title: Text(_metadataTitle(before['type'] as String)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (name != null) Text(name.toString()),
            if (remote == null)
              Text(_label(
                'The incoming change removes this record. Cashew checks for linked entries before applying it.',
                'التغيير الوارد يحذف السجل. يتحقق Cashew من القيود المرتبطة قبل تطبيقه.',
              ))
            else ...[
              for (final key in changes)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(labels[key] ?? key),
                  subtitle: Text([
                    _label('On this device · ${value(key, local[key])}',
                        'على هذا الجهاز · ${value(key, local[key])}'),
                    _label('Incoming · ${value(key, remote[key])}',
                        'الوارد · ${value(key, remote[key])}'),
                  ].join('\n')),
                ),
            ],
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: Text(_label('Cancel', 'إلغاء'))),
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(_label('Keep current', 'الاحتفاظ بالحالي'))),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(remote == null
                  ? _label('Delete record', 'حذف السجل')
                  : _label('Use incoming', 'استخدام الوارد'))),
        ],
      ),
    );
    if (result == null || !mounted) return;
    await database.resolveMetadataSyncConflict(
        conflict['conflict_pk'] as String,
        useRemote: result);
    if (mounted) setState(() => _conflicts = database.getOpenSyncConflicts());
  }

  Future<void> _review(Map<String, dynamic> conflict) async {
    setState(() => _busy = true);
    try {
      if (conflict['entity_type'] == 'metadata') {
        await _reviewMetadata(conflict);
        return;
      }
      final transfer = conflict['entity_type'] == 'transfer';
      final before =
          jsonDecode(conflict['local_json'] as String) as Map<String, dynamic>;
      final incoming = jsonDecode(conflict['remote_json'] as String);
      final local = transfer
          ? (before['rows'] as List)
              .cast<Map<String, dynamic>>()
              .map(Transaction.fromJson)
          : [Transaction.fromJson(before)];
      final isDeletion = transfer
          ? incoming['deletion'] == true
          : conflict['entity_type'] == 'transaction_delete';
      final canApply = !transfer || incoming['complete'] == true;
      final remote = transfer
          ? (incoming['rows'] as List)
              .cast<Map<String, dynamic>>()
              .map(Transaction.fromJson)
          : isDeletion
              ? <Transaction>[]
              : [Transaction.fromJson(incoming as Map<String, dynamic>)];
      final accounts = {
        for (final wallet in await database.getAllWallets())
          wallet.walletPk:
              '${wallet.name} ${wallet.currency?.toUpperCase() ?? ''}'.trim(),
      };
      final categories = {
        for (final category
            in await database.getAllCategories(includeSubCategories: true))
          category.categoryPk: category.name,
      };
      if (!mounted) return;
      final useRemote = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_label('Review sync conflict', 'مراجعة تعارض المزامنة')),
          scrollable: true,
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final row in local)
              _version(
                row,
                _label('Local version at detection',
                    'النسخة المحلية وقت اكتشاف التعارض'),
                accounts[row.walletFk],
                categories[row.categoryFk],
              ),
            if (transfer && !canApply)
              Text(_label(
                'The incoming change could not be verified as a complete transfer.',
                'تعذّر التحقق من أن التغيير الوارد يمثل تحويلاً كاملاً.',
              )),
            if (isDeletion && canApply)
              Text(transfer
                  ? _label('Another device deleted both transfer entries.',
                      'جهاز آخر حذف طرفي التحويل.')
                  : _label('Another device deleted this transaction.',
                      'جهاز آخر حذف هذه المعاملة.')),
            for (final row in remote)
              _version(row, _label('Incoming version', 'النسخة الواردة'),
                  accounts[row.walletFk], categories[row.categoryFk]),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(_label('Cancel', 'إلغاء'))),
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(_label('Keep current', 'الاحتفاظ بالحالي'))),
            if (canApply)
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(isDeletion
                    ? transfer
                        ? _label('Delete both entries', 'حذف الطرفين')
                        : _label('Delete transaction', 'حذف المعاملة')
                    : _label('Use incoming', 'استخدام الوارد')),
              ),
          ],
        ),
      );
      if (useRemote == null || !mounted) return;
      final id = conflict['conflict_pk'] as String;
      if (transfer) {
        await database.resolveTransferSyncConflict(id, useRemote: useRemote);
      } else {
        await database.resolveTransactionSyncConflict(id, useRemote: useRemote);
      }
      if (mounted) setState(() => _conflicts = database.getOpenSyncConflicts());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_label(
          'Could not apply this choice. The local entry may have changed or need manual review.',
          'تعذّر تطبيق الاختيار. ربما تغيّرت المعاملة المحلية أو تحتاج مراجعة يدوية.',
        ))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageFramework(
        title: _label('Sync conflicts', 'تعارضات المزامنة'),
        capitalizeTitle: false,
        listWidgets: [
          FutureBuilder(
            future: _conflicts,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done)
                return const LinearProgressIndicator();
              if (snapshot.hasError)
                return ListTile(
                    title: Text(
                  _label('Could not load conflicts.', 'تعذّر تحميل التعارضات.'),
                ));
              final conflicts = snapshot.data!
                  .where((row) => const {
                        'transaction',
                        'transaction_delete',
                        'transfer',
                        'metadata',
                      }.contains(row['entity_type']))
                  .toList();
              if (conflicts.isEmpty)
                return ListTile(
                    title: Text(
                  _label('No sync conflicts to review.',
                      'لا توجد تعارضات مزامنة للمراجعة.'),
                ));
              return Column(children: [
                for (final conflict in conflicts)
                  ListTile(
                    title: Text(switch (conflict['entity_type']) {
                      'transfer' => _label('Transfer conflict', 'تعارض تحويل'),
                      'metadata' => _label('Record conflict', 'تعارض سجل'),
                      'transaction_delete' =>
                        _label('Deletion conflict', 'تعارض حذف'),
                      _ => _label('Transaction conflict', 'تعارض معاملة'),
                    }),
                    subtitle:
                        Text(MaterialLocalizations.of(context).formatMediumDate(
                      DateTime.fromMillisecondsSinceEpoch(
                          conflict['detected_at'] as int),
                    )),
                    onTap: _busy ? null : () => _review(conflict),
                  ),
              ]);
            },
          ),
        ],
      );
}
