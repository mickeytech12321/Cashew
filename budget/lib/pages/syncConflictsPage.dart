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

  Widget _version(Transaction transaction, String heading, String? account, String? category) {
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
      final local = Transaction.fromJson(
        jsonDecode(conflict['local_json'] as String) as Map<String, dynamic>,
      );
      final isDeletion = conflict['entity_type'] == 'transaction_delete';
      final remote = isDeletion ? null : Transaction.fromJson(
        jsonDecode(conflict['remote_json'] as String) as Map<String, dynamic>,
      );
      final accounts = {
        for (final wallet in await database.getAllWallets())
          wallet.walletPk:
              '${wallet.name} ${wallet.currency?.toUpperCase() ?? ''}'.trim(),
      };
      final categories = {
        for (final category in await database.getAllCategories(includeSubCategories: true))
          category.categoryPk: category.name,
      };
      if (!mounted) return;
      final useRemote = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_label('Review sync conflict', 'مراجعة تعارض المزامنة')),
          scrollable: true,
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            _version(
                local,
                _label('Local version at detection',
                    'النسخة المحلية وقت اكتشاف التعارض'),
                accounts[local.walletFk], categories[local.categoryFk]),
            if (remote == null)
              Text(_label('Another device deleted this transaction.',
                  'جهاز آخر حذف هذه المعاملة.'))
            else
              _version(remote, _label('Incoming version', 'النسخة الواردة'),
                  accounts[remote.walletFk], categories[remote.categoryFk]),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(_label('Cancel', 'إلغاء'))),
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(_label('Keep current', 'الاحتفاظ بالحالي'))),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(isDeletion ? _label('Delete transaction', 'حذف المعاملة')
                    : _label('Use incoming', 'استخدام الوارد'))),
          ],
        ),
      );
      if (useRemote == null || !mounted) return;
      await database.resolveTransactionSyncConflict(
        conflict['conflict_pk'] as String,
        useRemote: useRemote,
      );
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
                  .where((row) => const {'transaction', 'transaction_delete'}
                      .contains(row['entity_type']))
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
                    title: Text(conflict['entity_type'] == 'transaction_delete'
                        ? _label('Deletion conflict', 'تعارض حذف')
                        : _label('Transaction conflict', 'تعارض معاملة')),
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
