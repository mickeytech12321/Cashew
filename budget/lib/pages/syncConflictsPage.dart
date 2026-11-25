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

  Future<void> _review(Map<String, dynamic> conflict) async {
    setState(() => _busy = true);
    try {
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
                        'transfer'
                      }.contains(row['entity_type']))
                  .toList();
              if (conflicts.isEmpty)
                return ListTile(
                    title: Text(
                  _label('No transaction conflicts to review.',
                      'لا توجد تعارضات معاملات للمراجعة.'),
                ));
              return Column(children: [
                for (final conflict in conflicts)
                  ListTile(
                    title: Text(switch (conflict['entity_type']) {
                      'transfer' => _label('Transfer conflict', 'تعارض تحويل'),
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
