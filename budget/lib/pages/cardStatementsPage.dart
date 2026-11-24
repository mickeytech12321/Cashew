import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/widgets/openPopup.dart';
import 'dart:convert';

import 'package:budget/struct/creditStatementCsv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/financialMessageParser.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  bool _onlyUnpaid = false;

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

  Future<void> _importCsv({String? pasted}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final String csv;
      if (pasted != null) {
        csv = pasted;
      } else {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['csv'],
          withData: true,
        );
        if (!mounted || result == null) return;
        final bytes = result.files.single.bytes;
        if (bytes == null || bytes.length > 65536)
          throw const FormatException();
        csv = utf8.decode(bytes);
      }
      final statements = parseCreditStatementCsv(csv);
      final dates = MaterialLocalizations.of(context);
      final currency = widget.wallet.currency ?? '';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title:
              Text(_label('Review statement import', 'مراجعة استيراد الكشوف')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_label(
                'Existing closing dates will be skipped. Amounts use this card’s currency.',
                'سيتم تخطي تواريخ الإقفال المسجّلة بالفعل. المبالغ بعملة البطاقة.')),
            for (final line in statements)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(dates.formatMediumDate(line.closed)),
                subtitle: Text(_amount(line.balance, currency)),
              ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(_label('Cancel', 'إلغاء'))),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(_label('Import statements', 'استيراد الكشوف'))),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final added = await database.importCreditCardStatements(
          widget.wallet.walletPk, statements);
      if (!mounted) return;
      setState(() => _statements =
          database.getCreditCardStatements(widget.wallet.walletPk));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_label(
        '$added statements imported.',
        'تم استيراد $added كشف حساب.',
      ))));
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
          _label(
              'Could not import the CSV. Check the header, dates and amounts.',
              'تعذّر استيراد الملف. تحقّق من أسماء الأعمدة والتواريخ والمبالغ.'),
        )));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pasteCsv() async {
    var text = '';
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_label('Paste statement CSV', 'لصق كشوف CSV')),
        content: TextField(
          minLines: 4,
          maxLines: 8,
          onChanged: (value) => text = value,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_label('Cancel', 'إلغاء'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, text),
              child: Text(_label('Preview', 'معاينة'))),
        ],
      ),
    );
    if (result != null && mounted) await _importCsv(pasted: result);
  }

  Future<void> _copyCsv(List<BankStatementLine> rows) async {
    try {
      await Clipboard.setData(
          ClipboardData(text: exportCreditStatementCsv(rows)));
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_label('Statements copied.', 'تم نسخ الكشوف.')),
        ));
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(_label('Could not copy statements.', 'تعذّر نسخ الكشوف.')),
        ));
    }
  }

  Future<void> _delete(DateTime closed) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_label('Delete this statement?', 'حذف كشف الحساب؟')),
        content:
            Text(MaterialLocalizations.of(context).formatMediumDate(closed)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_label('Cancel', 'إلغاء'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(_label('Delete', 'حذف'))),
        ],
      ),
    );
    if (!mounted || approved != true || _saving) return;
    setState(() => _saving = true);
    try {
      await database.deleteCreditCardStatement(widget.wallet.walletPk, closed);
      if (mounted)
        setState(() => _statements =
            database.getCreditCardStatements(widget.wallet.walletPk));
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_label(
              'Could not delete this statement.', 'تعذّر حذف كشف الحساب.')),
        ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _recordCardActivity({required bool refund}) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AddTransactionPage(
        selectedWallet: widget.wallet,
        selectedIncome: refund,
        selectedTitle: refund
            ? _label('Card refund', 'مرتجع البطاقة')
            : _label('Card fee', 'رسوم البطاقة'),
        routesToPopAfterDelete: RoutesToPopAfterDelete.None,
      ),
    ));
    if (mounted)
      setState(() => _statements =
          database.getCreditCardStatements(widget.wallet.walletPk));
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ExpansionTile(
            title: Text(
                _label('Import statements from CSV', 'استيراد الكشوف من CSV')),
            children: [
              ListTile(
                title: const SelectableText(creditStatementCsvHeader),
                subtitle: Text(_label(
                    'Use YYYY-MM-DD dates and decimal amounts.',
                    'استخدم تواريخ YYYY-MM-DD ومبالغ عشرية.')),
              ),
              OutlinedButton(
                onPressed: _saving ? null : _importCsv,
                child: Text(_label('Choose CSV file', 'اختر ملف CSV')),
              ),
              TextButton(
                onPressed: _saving ? null : _pasteCsv,
                child: Text(_label('Paste CSV', 'لصق CSV')),
              ),
            ],
          ),
        ),
        Wrap(
          alignment: WrapAlignment.center,
          children: [
            TextButton(
              onPressed:
                  _saving ? null : () => _recordCardActivity(refund: false),
              child: Text(_label('Record card fee', 'تسجيل رسوم البطاقة')),
            ),
            TextButton(
              onPressed:
                  _saving ? null : () => _recordCardActivity(refund: true),
              child: Text(_label('Record card refund', 'تسجيل مرتجع البطاقة')),
            ),
          ],
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
            final rows = snapshot.data!;
            final visible =
                rows.where((row) => !_onlyUnpaid || (!row.superseded && (row.remaining ?? 0) > 0));
            final export = [
              for (final row in rows)
                if (row.currency == widget.wallet.currency?.toLowerCase())
                  (
                    closed: row.closed,
                    due: row.due,
                    balance: row.balance,
                    minimum: row.minimum
                  ),
            ];
            return Column(children: [
              SwitchListTile(
                title: Text(_label('Show current unpaid statements only',
                    'عرض الكشوف الحالية غير المسددة فقط')),
                value: _onlyUnpaid,
                onChanged: (value) => setState(() => _onlyUnpaid = value),
              ),
              TextButton(
                onPressed: export.isEmpty ? null : () => _copyCsv(export),
                child: Text(_label('Copy statements in current currency as CSV',
                    'نسخ كشوف العملة الحالية بصيغة CSV')),
              ),
              if (visible.isEmpty)
                ListTile(
                    title: Text(_label(
                        'No matching statements.', 'لا توجد كشوف مطابقة.'))),
              for (final row in visible)
                ListTile(
                  title: Text(
                      '${dates.formatMediumDate(row.closed)} · ${_amount(row.balance, row.currency)}'),
                  subtitle: Text([
                    '${_label('Due', 'الاستحقاق')} ${dates.formatMediumDate(row.due)}',
                    '${_label('Bank minimum due', 'الحد الأدنى للسداد')} ${_amount(row.minimum, row.currency)}',
                    if (row.superseded)
                      _label('Closed by a newer statement', 'انتهت الفترة بكشف أحدث'),
                    if (row.credits != null)
                      '${_label('Credits in statement window', 'المبالغ الدائنة في فترة الكشف')} ${_amount(row.credits!, row.currency)}',
                    if (row.remaining != null)
                      '${_label('Estimated remaining balance', 'الرصيد المتبقي التقديري')} ${_amount(row.remaining!, row.currency)}',
                    if (row.minimumRemaining != null)
                      '${_label('Estimated minimum remaining', 'المتبقي التقديري من الحد الأدنى')} ${_amount(row.minimumRemaining!, row.currency)}',
                    if (row.overdue)
                      _label('Estimated minimum payment overdue',
                          'الحد الأدنى التقديري متأخر'),
                    if (row.ledgerBalance != null)
                      '${_label('Difference from recorded balance', 'الفرق عن الرصيد المسجّل')} '
                          '${_amount(row.balance - row.ledgerBalance!, row.currency)}',
                  ].join('\n')),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: _label('Delete statement', 'حذف كشف الحساب'),
                    onPressed: _saving ? null : () => _delete(row.closed),
                  ),
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
