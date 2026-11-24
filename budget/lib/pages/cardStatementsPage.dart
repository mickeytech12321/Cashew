import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/financialMessageParser.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:flutter/material.dart';

class CardStatementsPage extends StatefulWidget {
  const CardStatementsPage({required this.wallet, super.key});
  final TransactionWallet wallet;

  @override
  State<CardStatementsPage> createState() => _CardStatementsPageState();
}

class _CardStatementsPageState extends State<CardStatementsPage> {
  late var _statements =
      database.getCreditCardStatements(widget.wallet.walletPk);
  bool _saving = false;

  String _label(String en, String ar) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;

  Future<void> _edit([_StatementDraft? draft]) async {
    final result = await showDialog<_StatementDraft>(
      context: context,
      builder: (_) => _StatementEditor(label: _label, initial: draft),
    );
    if (result == null || !mounted) return;
    setState(() => _saving = true);
    try {
      await database.saveCreditCardStatement(
        walletPk: widget.wallet.walletPk,
        closingDate: result.closed,
        dueDate: result.due,
        statementBalance: result.balance,
        minimumDue: result.minimum,
      );
      if (mounted)
        setState(() => _statements =
            database.getCreditCardStatements(widget.wallet.walletPk));
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
          _label('Could not save this statement.', 'تعذّر حفظ كشف الحساب.'),
        )));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _amount(double value, String currency) =>
      '${value.toStringAsFixed(widget.wallet.decimals.clamp(0, 12))} ${currency.toUpperCase()}';

  @override
  Widget build(BuildContext context) {
    final dates = MaterialLocalizations.of(context);
    return PageFramework(
      title: _label('Card statements', 'كشوف البطاقة'),
      capitalizeTitle: false,
      listWidgets: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
              onPressed: _saving ? null : () => _edit(),
              child: Text(
                  _label('Record a bank statement', 'تسجيل كشف حساب بنكي'))),
        ),
        FutureBuilder(
          future: _statements,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done)
              return const LinearProgressIndicator();
            if (snapshot.hasError)
              return ListTile(
                  title: Text(
                _label(
                    'Could not load statements.', 'تعذّر تحميل كشوف الحساب.'),
              ));
            if (snapshot.data!.isEmpty)
              return ListTile(
                  title: Text(
                _label('No statements recorded.', 'لا توجد كشوف حساب مسجّلة.'),
              ));
            return Column(children: [
              for (final row in snapshot.data!)
                ListTile(
                  title: Text(
                      '${dates.formatMediumDate(row.closed)} · ${_amount(row.balance, row.currency)}'),
                  subtitle: Text([
                    '${_label('Due', 'الاستحقاق')} ${dates.formatMediumDate(row.due)}',
                    '${_label('Bank minimum due', 'الحد الأدنى للسداد')} ${_amount(row.minimum, row.currency)}',
                    if (row.ledgerBalance != null)
                      '${_label('Difference from recorded balance', 'الفرق عن الرصيد المسجّل')} '
                          '${_amount(row.balance - row.ledgerBalance!, row.currency)}',
                  ].join('\n')),
                  onTap: _saving ||
                          widget.wallet.currency?.toLowerCase() != row.currency
                      ? null
                      : () => _edit(_StatementDraft(
                          row.closed, row.due, row.balance, row.minimum)),
                ),
            ]);
          },
        ),
      ],
    );
  }
}

class _StatementDraft {
  const _StatementDraft(this.closed, this.due, this.balance, this.minimum);
  final DateTime closed;
  final DateTime due;
  final double balance;
  final double minimum;
}

class _StatementEditor extends StatefulWidget {
  const _StatementEditor({required this.label, this.initial});
  final String Function(String, String) label;
  final _StatementDraft? initial;

  @override
  State<_StatementEditor> createState() => _StatementEditorState();
}

class _StatementEditorState extends State<_StatementEditor> {
  final _form = GlobalKey<FormState>();
  late DateTime _closed =
      widget.initial?.closed ?? DateUtils.dateOnly(DateTime.now());
  late DateTime _due = widget.initial?.due ??
      DateTime(_closed.year, _closed.month, _closed.day + 15);
  late final _balance =
      TextEditingController(text: widget.initial?.balance.toString());
  late final _minimum =
      TextEditingController(text: widget.initial?.minimum.toString());

  @override
  void dispose() {
    _balance.dispose();
    _minimum.dispose();
    super.dispose();
  }

  double? _parse(String? text) =>
      double.tryParse(FinancialMessageParser.normalize(text?.trim() ?? ''));

  Widget _amountField(TextEditingController controller, String title,
          {bool minimum = false}) =>
      TextFormField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: title),
        validator: (text) {
          final value = _parse(text);
          if (value == null ||
              !value.isFinite ||
              value < 0 ||
              value > 999999999999) {
            return widget.label('Enter a valid amount', 'أدخل مبلغًا صالحًا');
          }
          if (minimum && value > (_parse(_balance.text) ?? 0)) {
            return widget.label('Minimum cannot exceed the balance',
                'الحد الأدنى لا يمكن أن يتجاوز الرصيد');
          }
          return null;
        },
      );

  Future<void> _pick({required bool due}) async {
    final firstDue = DateTime(_closed.year, _closed.month, _closed.day + 1);
    final result = await showDatePicker(
      context: context,
      firstDate: due ? firstDue : DateTime(1900),
      lastDate: due ? DateTime(2300) : DateTime.now(),
      initialDate: due ? (_due.isBefore(firstDue) ? firstDue : _due) : _closed,
    );
    if (result == null || !mounted) return;
    setState(() {
      if (due) {
        _due = result;
      } else {
        _closed = result;
        if (!_due.isAfter(_closed))
          _due = DateTime(result.year, result.month, result.day + 15);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.label;
    final dates = MaterialLocalizations.of(context);
    return AlertDialog(
      title: Text(label('Bank statement', 'كشف الحساب البنكي')),
      scrollable: true,
      content: Form(
        key: _form,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(label('Closing date', 'تاريخ الإقفال')),
            subtitle: Text(dates.formatMediumDate(_closed)),
            onTap: widget.initial == null ? () => _pick(due: false) : null,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(label('Due date', 'تاريخ الاستحقاق')),
            subtitle: Text(dates.formatMediumDate(_due)),
            onTap: () => _pick(due: true),
          ),
          _amountField(_balance, label('Statement balance', 'رصيد كشف الحساب')),
          _amountField(
              _minimum, label('Bank minimum due', 'الحد الأدنى للسداد'),
              minimum: true),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(label('Cancel', 'إلغاء'))),
        FilledButton(
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            Navigator.pop(
                context,
                _StatementDraft(_closed, _due, _parse(_balance.text)!,
                    _parse(_minimum.text)!));
          },
          child: Text(label('Save', 'حفظ')),
        ),
      ],
    );
  }
}
