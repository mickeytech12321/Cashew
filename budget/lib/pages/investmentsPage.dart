import 'package:budget/database/tables.dart' show NAME_LIMIT;
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/financialMessageParser.dart';
import 'package:budget/struct/investmentLedger.dart';
import 'package:budget/struct/investmentQuoteCsv.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:flutter/material.dart';

typedef _Holding = ({
  String id,
  String name,
  String currency,
  double? price,
  DateTime? priceAt,
});

class InvestmentsPage extends StatefulWidget {
  const InvestmentsPage({super.key});

  @override
  State<InvestmentsPage> createState() => _InvestmentsPageState();
}

class _InvestmentsPageState extends State<InvestmentsPage> {
  late var _holdings = database.getInvestmentHoldings();
  Future<List<InvestmentTrade>>? _trades;
  Future<List<({DateTime date, double price})>>? _prices;
  String? _selected;
  bool _busy = false;

  String _costBasisKey(String id) => 'investmentCostBasis.$id';

  Future<void> _saveCostBasis(String id, InvestmentCostBasis method) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (!await sharedPreferences.setString(_costBasisKey(id), method.name)) {
        throw StateError('Could not save investment view');
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
          _label('Could not save the cost basis method.',
              'تعذّر حفظ طريقة حساب التكلفة.'),
        )));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _label(String english, String arabic) =>
      Localizations.localeOf(context).languageCode == 'ar' ? arabic : english;

  Future<void> _write(Future<void> Function() write) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await write();
      if (!mounted) return;
      setState(() {
        _holdings = database.getInvestmentHoldings();
        final id = _selected;
        _trades = id == null ? null : database.getInvestmentTrades(id);
        _prices = id == null ? null : database.getInvestmentPriceHistory(id);
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_label(
          'Could not save. Check that sales never exceed units held on their date.',
          'تعذّر الحفظ. تأكد أن المبيعات لا تتجاوز الوحدات المملوكة في تاريخ البيع.',
        ))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(_InvestmentMode mode) async {
    final draft = await showDialog<_InvestmentDraft>(
      context: context,
      builder: (_) => _InvestmentEditor(mode: mode, label: _label),
    );
    if (draft == null || !mounted) return;
    final id = _selected;
    await _write(() async {
      switch (mode) {
        case _InvestmentMode.holding:
          final newId = uuid.v4();
          await database.createInvestmentHolding(
              id: newId, name: draft.name, currency: draft.currency);
          _selected = newId;
        case _InvestmentMode.trade:
          await database.addInvestmentTrade(
              id!,
              InvestmentTrade(
                id: uuid.v4(),
                date: draft.date,
                buy: draft.buy,
                units: draft.units,
                price: draft.price,
                fees: draft.fees,
              ));
        case _InvestmentMode.price:
          await database.setInvestmentMarketPrice(id!, draft.price, draft.date);
      }
    });
  }

  Future<void> _remove(InvestmentTrade trade) async {
    final id = _selected!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_label('Remove this trade?', 'حذف هذه الصفقة؟')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_label('Cancel', 'إلغاء'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(_label('Remove', 'حذف'))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _write(() => database.removeInvestmentTrade(id, trade.id));
  }

  String _money(double value, String currency) =>
      '${value.toStringAsFixed(2)} ${currency.toUpperCase()}';

  Future<void> _importQuotes(_Holding holding) async {
    var input = '';
    String? error;
    List<InvestmentQuote>? preview;
    final quotes = await showDialog<List<InvestmentQuote>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          scrollable: true,
          title: Text(_label('Import market prices', 'استيراد أسعار السوق')),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(holding.name),
              if (preview == null)
                TextField(
                  minLines: 4,
                  maxLines: 8,
                  onChanged: (value) => input = value,
                  decoration: InputDecoration(
                    labelText: _label('Paste CSV in ${holding.currency.toUpperCase()}',
                        'الصق CSV بعملة ${holding.currency.toUpperCase()}'),
                    hintText: 'date,price\n2026-01-20,123.45',
                    errorText: error,
                  ),
                )
              else ...[
                Text(_label('${preview!.length} quotes. Saved dates are skipped.',
                    '${preview!.length} سعرًا. يتم تخطي التواريخ المحفوظة.')),
                for (final quote in preview!.take(5))
                  ListTile(
                    title: Text(MaterialLocalizations.of(context)
                        .formatMediumDate(quote.date)),
                    trailing: Text(_money(quote.price, holding.currency)),
                  ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_label('Cancel', 'إلغاء')),
            ),
            FilledButton(
              onPressed: () {
                if (preview != null) {
                  Navigator.pop(context, preview);
                  return;
                }
                try {
                  final parsed = parseInvestmentQuoteCsv(input, DateTime.now());
                  update(() => preview = parsed);
                } on FormatException catch (failure) {
                  final row = RegExp(r'([0-9]+)$').firstMatch(failure.message.toString())?.group(1);
                  update(() => error = row == null
                      ? _label('Check the CSV header and row count.',
                          'راجع عنوان CSV وعدد الصفوف.')
                      : _label('Check row $row.', 'راجع الصف $row.'));
                }
              },
              child: Text(preview == null
                  ? _label('Preview', 'معاينة')
                  : _label('Import', 'استيراد')),
            ),
          ],
        ),
      ),
    );
    if (quotes == null || !mounted) return;
    await _write(() async {
      final added = await database.importInvestmentQuotes(holding.id, quotes);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_label(
        'Imported $added of ${quotes.length} quotes.',
        'تم استيراد $added من ${quotes.length} سعرًا.',
      ))));
    });
  }

  Widget _detail(_Holding holding) => FutureBuilder<List<InvestmentTrade>>(
        key: ValueKey(holding.id),
        future: _trades,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done)
            return const LinearProgressIndicator();
          if (!snapshot.hasData)
            return ListTile(
                title: Text(_label(
              'Could not load trades.',
              'تعذّر تحميل الصفقات.',
            )));
          final trades = snapshot.data!;
          final method = sharedPreferences.getString(_costBasisKey(holding.id)) ==
                  InvestmentCostBasis.fifo.name
              ? InvestmentCostBasis.fifo
              : InvestmentCostBasis.weightedAverage;
          final InvestmentBalance balance;
          try {
            balance = InvestmentBalance.fromTrades(trades,
                method: method, includeBreakdown: true);
          } on StateError {
            return ListTile(
              title: Text(_label('Could not calculate holdings.',
                  'تعذّر حساب الوحدات المملوكة.')),
            );
          }
          final price = holding.price;
          final valuation = price == null ? null : balance.units * price;
          final dates = MaterialLocalizations.of(context);
          return Column(children: [
            ListTile(
              title: Text(_label('Cost basis method', 'طريقة حساب التكلفة')),
              trailing: DropdownButton<InvestmentCostBasis>(
                value: method,
                items: [
                  DropdownMenuItem(
                    value: InvestmentCostBasis.weightedAverage,
                    child: Text(_label('Weighted average', 'المتوسط المرجّح')),
                  ),
                  DropdownMenuItem(
                    value: InvestmentCostBasis.fifo,
                    child: Text(_label('FIFO', 'الأقدم أولًا')),
                  ),
                ],
                onChanged: _busy ? null : (value) {
                  if (value != null) _saveCostBasis(holding.id, value);
                },
              ),
            ),
            ListTile(
              title: Text(_label('Units held', 'الوحدات المملوكة')),
              trailing: Text(balance.units.toStringAsFixed(6)),
            ),
            ListTile(
              title: Text(
                  _label('Remaining cost basis', 'تكلفة الوحدات المتبقية')),
              trailing: Text(_money(balance.cost, holding.currency)),
            ),
            ListTile(
              title: Text(
                  _label('Realized gain or loss', 'الربح أو الخسارة المحققة')),
              trailing: Text(_money(balance.realized, holding.currency)),
            ),
            if (balance.openLots.isNotEmpty)
              ExpansionTile(
                title: Text(_label('Open purchase lots', 'دفعات الشراء المتبقية')),
                children: [
                  for (final lot in balance.openLots)
                    ListTile(
                      title: Text(dates.formatMediumDate(lot.date)),
                      subtitle: Text(lot.units.toStringAsFixed(6)),
                      trailing: Text(_money(lot.cost, holding.currency)),
                    ),
                ],
              ),
            if (valuation != null && valuation.isFinite) ...[
              ListTile(
                title: Text(_label('Market value', 'القيمة السوقية')),
                subtitle: holding.priceAt == null
                    ? null
                    : Text(dates.formatMediumDate(holding.priceAt!)),
                trailing: Text(_money(valuation, holding.currency)),
              ),
              ListTile(
                title: Text(_label(
                    'Unrealized gain or loss', 'الربح أو الخسارة غير المحققة')),
                trailing:
                    Text(_money(valuation - balance.cost, holding.currency)),
              ),
            ],
            Wrap(children: [
              TextButton(
                  onPressed: _busy ? null : () => _edit(_InvestmentMode.trade),
                  child: Text(_label('Record trade', 'تسجيل صفقة'))),
              TextButton(
                  onPressed: _busy ? null : () => _edit(_InvestmentMode.price),
                  child: Text(_label('Set market price', 'تحديد سعر السوق'))),
              TextButton(
                  onPressed: _busy ? null : () => _importQuotes(holding),
                  child: Text(_label('Import prices', 'استيراد الأسعار'))),
            ]),
            FutureBuilder(
              key: ValueKey(('prices', holding.id)),
              future: _prices,
              builder: (context, snapshot) {
                if (snapshot.hasError)
                  return ListTile(
                      title: Text(
                    _label('Could not load price history.',
                        'تعذّر تحميل سجل الأسعار.'),
                  ));
                final prices = snapshot.data;
                if (prices == null || prices.isEmpty)
                  return const SizedBox.shrink();
                return ExpansionTile(
                  title: Text(
                      _label('Price history', 'سجل الأسعار')),
                  children: [
                    for (final quote in prices)
                      ListTile(
                        title: Text(dates.formatMediumDate(quote.date)),
                        trailing: Text(_money(quote.price, holding.currency)),
                      ),
                  ],
                );
              },
            ),
            for (final trade in trades.reversed)
              ListTile(
                title: Text(
                    '${trade.buy ? _label('Buy', 'شراء') : _label('Sell', 'بيع')} · ${trade.units}'),
                subtitle: Text([
                  '${dates.formatMediumDate(trade.date)} · ${_money(trade.price, holding.currency)}',
                  if (balance.realizedBySale[trade.id] case final gain?)
                    '${_label('Realized gain or loss', 'الربح أو الخسارة المحققة')} '
                        '${_money(gain, holding.currency)}',
                ].join('\n')),
                trailing: IconButton(
                  tooltip: _label('Remove trade', 'حذف الصفقة'),
                  onPressed: _busy ? null : () => _remove(trade),
                  icon: const Icon(Icons.delete_outline),
                ),
              ),
          ]);
        },
      );

  @override
  Widget build(BuildContext context) => PageFramework(
        title: _label('Investments', 'الاستثمارات'),
        capitalizeTitle: false,
        listWidgets: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
                onPressed: _busy ? null : () => _edit(_InvestmentMode.holding),
                child: Text(_label('Add holding', 'إضافة أصل استثماري'))),
          ),
          FutureBuilder<List<_Holding>>(
            future: _holdings,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done)
                return const LinearProgressIndicator();
              if (!snapshot.hasData)
                return ListTile(
                    title: Text(
                  _label(
                      'Could not load holdings.', 'تعذّر تحميل الاستثمارات.'),
                ));
              final holdings = snapshot.data!;
              final selected = holdings
                  .where((holding) => holding.id == _selected)
                  .firstOrNull;
              return Column(children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DropdownButton<String>(
                    isExpanded: true,
                    hint:
                        Text(_label('Choose holding', 'اختر أصلًا استثماريًا')),
                    value: selected?.id,
                    items: [
                      for (final holding in holdings)
                        DropdownMenuItem(
                            value: holding.id,
                            child: Text(
                                '${holding.name} · ${holding.currency.toUpperCase()}')),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) {
                            if (value != null)
                              setState(() {
                                _selected = value;
                                _trades = database.getInvestmentTrades(value);
                                _prices = database.getInvestmentPriceHistory(value);
                              });
                          },
                  ),
                ),
                if (selected != null) _detail(selected),
              ]);
            },
          ),
        ],
      );
}

enum _InvestmentMode { holding, trade, price }

class _InvestmentDraft {
  const _InvestmentDraft(this.name, this.currency, this.units, this.price,
      this.fees, this.date, this.buy);
  final String name;
  final String currency;
  final double units;
  final double price;
  final double fees;
  final DateTime date;
  final bool buy;
}

class _InvestmentEditor extends StatefulWidget {
  const _InvestmentEditor({required this.mode, required this.label});
  final _InvestmentMode mode;
  final String Function(String, String) label;

  @override
  State<_InvestmentEditor> createState() => _InvestmentEditorState();
}

class _InvestmentEditorState extends State<_InvestmentEditor> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _currency = TextEditingController();
  final _units = TextEditingController(text: '1');
  final _price = TextEditingController();
  final _fees = TextEditingController(text: '0');
  DateTime _date = DateUtils.dateOnly(DateTime.now());
  bool _buy = true;

  @override
  void dispose() {
    for (final controller in [_name, _currency, _units, _price, _fees]) {
      controller.dispose();
    }
    super.dispose();
  }

  double? _number(String? value) =>
      double.tryParse(FinancialMessageParser.normalize(value?.trim() ?? ''));

  Widget _numeric(TextEditingController controller, String label,
          {bool zero = false}) =>
      TextFormField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label),
        validator: (text) {
          final number = _number(text);
          return number != null &&
                  number.isFinite &&
                  (zero ? number >= 0 : number > 0)
              ? null
              : widget.label('Enter a valid number', 'أدخل رقمًا صالحًا');
        },
      );

  @override
  Widget build(BuildContext context) {
    final label = widget.label;
    final holding = widget.mode == _InvestmentMode.holding;
    final trade = widget.mode == _InvestmentMode.trade;
    return AlertDialog(
      title: Text(holding
          ? label('Add holding', 'إضافة أصل استثماري')
          : trade
              ? label('Record trade', 'تسجيل صفقة')
              : label('Market price', 'سعر السوق')),
      scrollable: true,
      content: Form(
        key: _form,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (holding) ...[
            TextFormField(
              controller: _name,
              maxLength: NAME_LIMIT,
              decoration: InputDecoration(
                  labelText: label('Holding name', 'اسم الأصل')),
              validator: (value) => value?.trim().isNotEmpty == true
                  ? null
                  : label('Enter a name', 'أدخل اسمًا'),
            ),
            TextFormField(
              controller: _currency,
              maxLength: 3,
              decoration: InputDecoration(
                  labelText: label('Currency code', 'رمز العملة')),
              validator: (value) => RegExp(r'^[a-zA-Z]{3}$')
                      .hasMatch(value?.trim() ?? '')
                  ? null
                  : label(
                      'Enter a three-letter code', 'أدخل رمزًا من ثلاثة أحرف'),
            ),
          ] else ...[
            if (trade) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_buy ? label('Buy', 'شراء') : label('Sell', 'بيع')),
                value: _buy,
                onChanged: (value) => setState(() => _buy = value),
              ),
              _numeric(_units, label('Units', 'الوحدات')),
            ],
            _numeric(_price, label('Price per unit', 'سعر الوحدة'),
                zero: !trade),
            if (trade) _numeric(_fees, label('Fees', 'الرسوم'), zero: true),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                  MaterialLocalizations.of(context).formatMediumDate(_date)),
              trailing: const Icon(Icons.calendar_today_outlined),
              onTap: () async {
                final day = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime(1900),
                    lastDate: DateTime.now());
                if (mounted && day != null) setState(() => _date = day);
              },
            ),
          ],
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
                  _InvestmentDraft(
                    _name.text,
                    _currency.text,
                    _number(_units.text) ?? 0,
                    _number(_price.text) ?? 0,
                    _number(_fees.text) ?? 0,
                    _date,
                    _buy,
                  ));
            },
            child: Text(label('Save', 'حفظ'))),
      ],
    );
  }
}
