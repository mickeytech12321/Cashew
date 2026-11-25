import 'dart:convert';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:flutter/material.dart';

class TransferHistoryPage extends StatefulWidget {
  const TransferHistoryPage({super.key});

  @override
  State<TransferHistoryPage> createState() => _TransferHistoryPageState();
}

class _TransferHistoryPageState extends State<TransferHistoryPage> {
  static const _pageSize = 25;
  int _offset = 0;
  bool _busy = false;
  late var _actions = _load();

  Future<List<Map<String, dynamic>>> _load() =>
      database.getLocalFinancialActions(limit: _pageSize + 1, offset: _offset);

  String _label(String english, String arabic) =>
      Localizations.localeOf(context).languageCode == 'ar' ? arabic : english;

  void _notify(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _move(int offset) => setState(() {
        _offset = offset;
        _actions = _load();
      });

  Future<void> _review(Map<String, dynamic> action) async {
    final id = action['action_pk'] as String;
    final undone = action['undone_at'] != null;
    setState(() => _busy = true);
    try {
      final changes = await database.getLocalFinancialActionChanges(id);
      final transfers = changes
          .map((change) => Transaction.fromJson(
              jsonDecode(change['after_json'] as String)
                  as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(undone
              ? _label('Restore this transfer?', 'استعادة هذا التحويل؟')
              : _label('Undo this transfer?', 'التراجع عن هذا التحويل؟')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final transfer in transfers)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(transfer.name),
                  trailing: Icon(transfer.amount < 0
                      ? Icons.north_east
                      : Icons.south_west),
                  subtitle: Text(
                    '${_label(
                      transfer.amount < 0 ? 'Outgoing entry' : 'Incoming entry',
                      transfer.amount < 0 ? 'معاملة صادرة' : 'معاملة واردة',
                    )} · ${transfer.amount.abs()}',
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(_label('Cancel', 'إلغاء'))),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(undone
                    ? _label('Restore transfer', 'استعادة التحويل')
                    : _label('Undo transfer', 'التراجع عن التحويل'))),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final changed = undone
          ? await database.redoLocalTransfer(id)
          : await database.undoLocalTransfer(id);
      if (!mounted) return;
      if (!changed)
        _notify(
            _label('The transfer status has changed.', 'تغيّرت حالة التحويل.'));
      setState(() => _actions = _load());
    } catch (_) {
      if (mounted)
        _notify(_label(
          'Could not change this transfer. Its entries may have changed.',
          'تعذّر تغيير التحويل. ربما تغيّرت معاملاته.',
        ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dates = MaterialLocalizations.of(context);
    return PageFramework(
      title: _label('Transfer history', 'سجل التحويلات'),
      capitalizeTitle: false,
      listWidgets: [
        FutureBuilder(
          future: _actions,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const LinearProgressIndicator();
            }
            if (snapshot.hasError) {
              return ListTile(
                  title: Text(_label(
                'Could not load transfer history.',
                'تعذّر تحميل سجل التحويلات.',
              )));
            }
            final actions = snapshot.data!;
            return Column(children: [
              if (actions.isEmpty)
                ListTile(
                    title: Text(_label(
                  'No transfers recorded in the local history.',
                  'لا توجد تحويلات في السجل المحلي.',
                ))),
              for (final action in actions.take(_pageSize))
                if (action['action_type'] == 'transfer')
                  ListTile(
                    leading: Icon(action['undone_at'] == null
                        ? Icons.swap_horiz
                        : Icons.undo),
                    title: Text(action['undone_at'] == null
                        ? _label('Transfer', 'تحويل')
                        : _label('Undone transfer', 'تحويل تم التراجع عنه')),
                    subtitle: Text(dates.formatMediumDate(
                      DateTime.fromMillisecondsSinceEpoch(
                          action['created_at'] as int),
                    )),
                    onTap: _busy ? null : () => _review(action),
                  ),
              if (_offset > 0 || actions.length > _pageSize)
                Wrap(children: [
                  TextButton(
                      onPressed: _busy || _offset == 0
                          ? null
                          : () => _move(_offset - _pageSize),
                      child: Text(_label('Previous', 'السابق'))),
                  TextButton(
                      onPressed: _busy || actions.length <= _pageSize
                          ? null
                          : () => _move(_offset + _pageSize),
                      child: Text(_label('Next', 'التالي'))),
                ]),
            ]);
          },
        ),
      ],
    );
  }
}
