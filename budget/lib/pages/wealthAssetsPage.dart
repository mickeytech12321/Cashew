import 'package:budget/database/tables.dart';
import 'package:budget/widgets/cashuSurfaces.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/financialMessageParser.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:flutter/material.dart';

class WealthAssetsPage extends StatefulWidget {
  const WealthAssetsPage({super.key, this.initialAssetType});
  final String? initialAssetType;

  @override
  State<WealthAssetsPage> createState() => _WealthAssetsPageState();
}

class _WealthAssetsPageState extends State<WealthAssetsPage> {
  late var _assets = database.getWealthAssets();
  bool _busy = false;
  String _valuationCurrency = 'egp';
  bool _includeInvestments = false;
  int _view = 0;
  int _historyMonths = 3;
  late final _accountBalances =
      database.watchCashuOverviewAccounts(DateTime.now(), DateTime.now());
  late var _valuation = database.getWealthValuation(_valuationCurrency,
      includeInvestments: _includeInvestments);
  late var _allocation = database.getWealthAllocation();
  late var _history = database.getWealthSnapshotHistory();

  String _label(String english, String arabic) =>
      Localizations.localeOf(context).languageCode == 'ar' ? arabic : english;

  Future<void> _write(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted)
        setState(() {
          _assets = database.getWealthAssets();
          _valuation = database.getWealthValuation(_valuationCurrency,
              includeInvestments: _includeInvestments);
          _history = database.getWealthSnapshotHistory();
          _allocation = database.getWealthAllocation();
        });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(_label('Could not save the change.', 'تعذّر حفظ التغيير.')),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialAssetType != null) {
      _view = widget.initialAssetType == 'debt' ? 2 : 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _edit(null, widget.initialAssetType);
      });
    }
  }

  Future<void> _edit([Map<String, dynamic>? asset, String? initialType]) async {
    final values = await showDialog<_AssetDraft>(
      context: context,
      builder: (context) => _AssetEditor(
        asset: asset,
        initialType: initialType,
        label: _label,
      ),
    );
    if (values == null || !mounted) return;
    await _write(() => database.saveWealthAsset(
          assetPk: asset?['asset_pk'] as String? ?? uuid.v4(),
          name: values.name,
          assetType: values.type,
          currency: values.currency,
          quantity: values.quantity,
          unitValue: values.unitValue,
          liability: values.liability,
          institutionName: asset?['institution_name'] as String?,
          notes: asset?['notes'] as String?,
        ));
  }

  Future<void> _delete(Map<String, dynamic> asset) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_label('Delete this entry?', 'حذف هذا البند؟')),
        content: Text(asset['name'] as String),
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
    if (result == true && mounted) {
      await _write(
          () => database.deleteWealthAsset(asset['asset_pk'] as String));
    }
  }

  Future<void> _captureSnapshot() => _write(() async {
        final captured = await database.captureWealthSnapshot(
          snapshotPk: uuid.v4(),
          capturedAt: DateTime.now(),
          currency: _valuationCurrency,
          includeInvestments: _includeInvestments,
        );
        if (!captured && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_label(
                'A complete valuation is required.', 'يلزم توفر تقييم كامل.')),
          ));
        }
      });

  Widget _valuationPanel(Set<String> currencies) {
    final options = {'egp', 'usd', _valuationCurrency, ...currencies}.toList()
      ..sort();
    return FutureBuilder(
      key: ValueKey(_valuationCurrency),
      future: _valuation,
      builder: (context, snapshot) {
        final value = snapshot.data;
        return ListTile(
          contentPadding: EdgeInsets.zero,
          textColor: const Color(0xfff2faf4),
          title: Text(_label('Net recorded assets', 'صافي الأصول المسجّلة')),
          subtitle: snapshot.connectionState != ConnectionState.done
              ? const LinearProgressIndicator()
              : Text(
                  value?.total != null
                      ? _amount(value!.total!, _valuationCurrency)
                      : value != null && value.missingCurrencies.isNotEmpty
                          ? '${_label('Missing exchange rates', 'أسعار الصرف غير المتاحة')} '
                              '${value.missingCurrencies.join(', ').toUpperCase()}'
                          : value != null && value.unpricedHoldings > 0
                              ? _label('Enter prices for all open investments.',
                                  'أدخل أسعار كل الاستثمارات المفتوحة.')
                              : _label('No valuation yet', 'لسه مفيش تقييم'),
                  style: TextStyle(
                      fontSize: value?.total == null ? 14 : 27,
                      fontWeight: FontWeight.w800,
                      color: const Color(0xfff2faf4))),
          trailing: DropdownButton<String>(
            dropdownColor: const Color(0xff254b3b),
            style: const TextStyle(
                color: Color(0xfff2faf4), fontWeight: FontWeight.w700),
            iconEnabledColor: const Color(0xffb4edb8),
            value: _valuationCurrency,
            items: [
              for (final code in options)
                DropdownMenuItem(value: code, child: Text(code.toUpperCase())),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    if (value == null) return;
                    setState(() {
                      _valuationCurrency = value;
                      _valuation = database.getWealthValuation(value,
                          includeInvestments: _includeInvestments);
                    });
                  },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => PageFramework(
        title: _label('Wealth', 'الثروة'),
        horizontalPaddingConstrained: true,
        backgroundColor: CashuColors(context).canvas,
        capitalizeTitle: false,
        listWidgets: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 7),
            child: Wrap(spacing: 9, runSpacing: 6, children: [
              for (final (id, title) in [
                (0, _label('Overview', 'نظرة عامة')),
                (1, _label('Assets', 'الأصول')),
                (2, _label('Debt', 'الديون')),
              ])
                ChoiceChip(
                    label: Text(title),
                    selected: _view == id,
                    onSelected: (_) => setState(() => _view = id)),
              ActionChip(
                avatar: const Icon(Icons.add, size: 18),
                label: Text(_label('Add entry', 'إضافة بند')),
                onPressed: _busy
                    ? null
                    : () => _edit(null, _view == 2 ? 'debt' : null),
              ),
            ]),
          ),
          if (_view == 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: CashuGreenPanel(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FutureBuilder<List<Map<String, dynamic>>>(
                    future: _assets,
                    builder: (context, snapshot) => _valuationPanel({
                      for (final asset
                          in snapshot.data ?? const <Map<String, dynamic>>[])
                        (asset['currency'] as String).toLowerCase(),
                    }),
                  ),
                  StreamBuilder<List<CashuOverviewAccount>>(
                    stream: _accountBalances,
                    builder: (context, snapshot) {
                      final rows = snapshot.data;
                      if (rows == null) return const SizedBox.shrink();
                      final balances = <String, double>{};
                      for (final account
                          in rows.where((a) => !a.excludeFromNetWorth)) {
                        balances.update(account.currency,
                            (value) => value + account.balance,
                            ifAbsent: () => account.balance);
                      }
                      if (balances.isEmpty) return const SizedBox.shrink();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 8),
                          Text(_label('Account balances', 'أرصدة الحسابات'),
                              style: const TextStyle(color: Color(0xffc5d9cc))),
                          const SizedBox(height: 4),
                          for (final entry in balances.entries)
                            Text(_amount(entry.value, entry.key),
                                style: const TextStyle(
                                    color: Color(0xffeff8f0),
                                    fontWeight: FontWeight.w700)),
                        ],
                      );
                    },
                  ),
                ],
              )),
            ),
          if (_view == 0)
            SwitchListTile(
              title: Text(_label(
                  'Include tracked investments', 'تضمين الاستثمارات المسجّلة')),
              subtitle: Text(_label(
                'Enable when these holdings are recorded only under Investments.',
                'فعّل الخيار لو الأصول دي مسجّلة في الاستثمارات فقط.',
              )),
              value: _includeInvestments,
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                        _includeInvestments = value;
                        _valuation = database.getWealthValuation(
                            _valuationCurrency,
                            includeInvestments: value);
                      }),
            ),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _assets,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return ListTile(
                    title: Text(_label(
                        'Could not load assets.', 'تعذّر تحميل الأصول.')));
              }
              if (!snapshot.hasData) return const LinearProgressIndicator();
              final allAssets = snapshot.data!;
              final assets = _view == 0
                  ? allAssets
                  : allAssets
                      .where(
                          (asset) => (asset['liability'] == 1) == (_view == 2))
                      .toList();
              final balances = <String, double>{};
              for (final asset in assets) {
                final currency = (asset['currency'] as String).toUpperCase();
                balances.update(
                  currency,
                  (old) => old + _value(asset),
                  ifAbsent: () => _value(asset),
                );
              }
              return Column(
                children: [
                  if (assets.isEmpty)
                    ListTile(
                        title: Text(
                            _label('No entries yet.', 'لا توجد بنود بعد.'))),
                  if (_view == 0 && (assets.isNotEmpty || _includeInvestments))
                    OutlinedButton(
                      onPressed: _busy ? null : _captureSnapshot,
                      child: Text(_label(
                          'Save valuation snapshot', 'حفظ لقطة للتقييم')),
                    ),
                  for (final balance in balances.entries)
                    ListTile(
                      title: Text(_view == 1
                          ? _label('Asset value', 'قيمة الأصول')
                          : _view == 2
                              ? _label('Debt balance', 'رصيد الديون')
                              : _label('Net recorded value',
                                  'صافي القيمة المسجّلة')),
                      trailing: Text(_amount(balance.value, balance.key)),
                    ),
                  for (final asset in assets)
                    Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                        child: CashuPanel(
                            padding: EdgeInsets.zero,
                            child: ListTile(
                              title: Text(asset['name'] as String),
                              subtitle: Text(_amount(
                                  _value(asset), asset['currency'] as String)),
                              leading: Icon(asset['liability'] == 1
                                  ? Icons.trending_down
                                  : Icons.account_balance_outlined),
                              onTap: _busy ? null : () => _edit(asset),
                              trailing: IconButton(
                                tooltip: _label('Delete entry', 'حذف البند'),
                                onPressed: _busy ? null : () => _delete(asset),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ))),
                ],
              );
            },
          ),
          if (_view == 0)
            FutureBuilder(
              future: _allocation,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const LinearProgressIndicator();
                }
                if (snapshot.hasError)
                  return ListTile(
                      title: Text(
                    _label('Could not load allocation.',
                        'تعذّر تحميل توزيع الأصول.'),
                  ));
                final allocation = snapshot.data!;
                if (allocation.isEmpty) return const SizedBox.shrink();
                final totals = <(String, bool), double>{};
                for (final row in allocation) {
                  totals.update((
                    row.currency,
                    row.liability
                  ), (total) => total + row.value, ifAbsent: () => row.value);
                }
                return ExpansionTile(
                  title:
                      Text(_label('Allocation by type', 'التوزيع حسب النوع')),
                  children: [
                    for (final row in allocation)
                      ListTile(
                        title: Text(row.type),
                        subtitle: Text(row.liability
                            ? _label('Liabilities', 'الالتزامات')
                            : _label('Assets', 'الأصول')),
                        trailing: Text([
                          _amount(row.value, row.currency),
                          if (totals[(row.currency, row.liability)]! > 0)
                            '${(row.value / totals[(
                                  row.currency,
                                  row.liability
                                )]! * 100).toStringAsFixed(1)}%',
                        ].join(' · ')),
                      ),
                  ],
                );
              },
            ),
          if (_view == 0)
            FutureBuilder(
              future: _history,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return ListTile(
                      title: Text(_label('Could not load snapshot history.',
                          'تعذّر تحميل سجل التقييمات.')));
                }
                final history = snapshot.data;
                if (history == null || history.isEmpty)
                  return const SizedBox.shrink();
                final dates = MaterialLocalizations.of(context);
                final cutoff = DateUtils.addMonthsToMonthDate(
                    DateTime.now(), -_historyMonths);
                final points = history.reversed
                    .where((entry) =>
                        entry.currency == _valuationCurrency &&
                        entry.includesInvestments == _includeInvestments &&
                        entry.total.isFinite &&
                        (_historyMonths == 0 ||
                            !entry.capturedAt.isBefore(cutoff)))
                    .toList();
                return Column(
                  children: [
                    ListTile(
                        title:
                            Text(_label('Valuation history', 'سجل التقييمات'))),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: CashuPanel(
                          child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Wrap(spacing: 8, children: [
                            for (final (months, title) in [
                              (3, _label('3 months', '٣ شهور')),
                              (12, _label('1 year', 'سنة')),
                              (0, _label('All time', 'كل الفترة')),
                            ])
                              ChoiceChip(
                                label: Text(title),
                                selected: _historyMonths == months,
                                onSelected: (_) =>
                                    setState(() => _historyMonths = months),
                              ),
                          ]),
                          if (points.length >= 2) ...[
                            const SizedBox(height: 12),
                            SizedBox(
                                height: 98,
                                child: CustomPaint(
                                  painter: _ValuationLine([
                                    for (final entry in points)
                                      (
                                        entry.capturedAt.millisecondsSinceEpoch,
                                        entry.total
                                      ),
                                  ], CashuColors(context).accent),
                                )),
                            const SizedBox(height: 8),
                            Text(
                                '${dates.formatMediumDate(points.first.capturedAt)} – ${dates.formatMediumDate(points.last.capturedAt)}'),
                          ] else
                            Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 10),
                                child: Text(_label(
                                    'Save two valuations to see a trend for this period.',
                                    'احفظ تقييمين لعرض الاتجاه خلال الفترة.'))),
                        ],
                      )),
                    ),
                    for (final entry in history)
                      ListTile(
                        title: Text(dates.formatMediumDate(entry.capturedAt)),
                        subtitle: entry.includesInvestments
                            ? Text(_label(
                                'Includes investments', 'يشمل الاستثمارات'))
                            : null,
                        trailing:
                            Text(_amount(entry.total, entry.currency ?? '')),
                      ),
                  ],
                );
              },
            ),
        ],
      );

  double _value(Map<String, dynamic> asset) =>
      (asset['quantity'] as num).toDouble() *
      (asset['unit_value'] as num).toDouble() *
      (asset['liability'] == 1 ? -1 : 1);

  String _amount(double value, String currency) =>
      '${value.toStringAsFixed(2)} ${currency.toUpperCase()}';
}

class _ValuationLine extends CustomPainter {
  const _ValuationLine(this.points, this.color);

  final List<(int, double)> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final start = points.first.$1;
    final duration = points.last.$1 - start;
    final values = points.map((point) => point.$2);
    final low = values.reduce((a, b) => a < b ? a : b);
    final high = values.reduce((a, b) => a > b ? a : b);
    const inset = 5.0;
    final line = Path();
    Offset end = Offset.zero;
    for (var i = 0; i < points.length; i++) {
      final point = points[i];
      final fraction = duration == 0
          ? i / (points.length - 1)
          : (point.$1 - start) / duration;
      final normalized = high == low ? .5 : (point.$2 - low) / (high - low);
      end = Offset(
        inset + fraction * (size.width - inset * 2),
        inset + (1 - normalized) * (size.height - inset * 2),
      );
      if (i == 0) {
        line.moveTo(end.dx, end.dy);
      } else {
        line.lineTo(end.dx, end.dy);
      }
    }
    canvas.drawPath(
        line,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 2.5);
    canvas.drawCircle(end, 4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ValuationLine oldDelegate) =>
      oldDelegate.points != points || oldDelegate.color != color;
}

class _AssetDraft {
  const _AssetDraft(this.name, this.type, this.currency, this.quantity,
      this.unitValue, this.liability);

  final String name;
  final String type;
  final String currency;
  final double quantity;
  final double unitValue;
  final bool liability;
}

class _AssetEditor extends StatefulWidget {
  const _AssetEditor({this.asset, this.initialType, required this.label});

  final Map<String, dynamic>? asset;
  final String? initialType;
  final String Function(String, String) label;

  @override
  State<_AssetEditor> createState() => _AssetEditorState();
}

class _AssetEditorState extends State<_AssetEditor> {
  final _form = GlobalKey<FormState>();
  late final _name =
      TextEditingController(text: widget.asset?['name'] as String?);
  late final _type = TextEditingController(
      text: widget.asset?['asset_type'] as String? ?? widget.initialType);
  late final _currency = TextEditingController(
      text: widget.asset?['currency'] as String? ?? 'egp');
  late final _quantity =
      TextEditingController(text: widget.asset?['quantity']?.toString() ?? '1');
  late final _unitValue =
      TextEditingController(text: widget.asset?['unit_value']?.toString());
  late bool _liability =
      widget.asset?['liability'] == 1 || widget.initialType == 'debt';

  @override
  void dispose() {
    for (final controller in [_name, _type, _currency, _quantity, _unitValue]) {
      controller.dispose();
    }
    super.dispose();
  }

  double? _number(String? input) =>
      double.tryParse(FinancialMessageParser.normalize(input?.trim() ?? ''));

  @override
  Widget build(BuildContext context) {
    final label = widget.label;
    Widget textField(TextEditingController controller, String title,
            {String? Function(String?)? validator, bool numeric = false}) =>
        TextFormField(
          controller: controller,
          decoration: InputDecoration(labelText: title),
          keyboardType: numeric
              ? const TextInputType.numberWithOptions(decimal: true)
              : null,
          validator: validator ??
              (value) => value?.trim().isNotEmpty == true
                  ? null
                  : label('Required', 'مطلوب'),
        );
    String? numericValidator(String? input) {
      final value = _number(input);
      return value != null && value.isFinite && value >= 0
          ? null
          : label('Enter a non-negative number', 'أدخل رقمًا غير سالب');
    }

    return AlertDialog(
      title: Text(widget.asset == null
          ? label('Add entry', 'إضافة بند')
          : label('Edit entry', 'تعديل البند')),
      scrollable: true,
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            textField(_name, label('Name', 'الاسم')),
            textField(_type,
                label('Asset or liability type', 'نوع الأصل أو الالتزام')),
            textField(
              _currency,
              label('Currency code', 'رمز العملة'),
              validator: (value) =>
                  RegExp(r'^[a-zA-Z]{3}$').hasMatch(value?.trim() ?? '')
                      ? null
                      : label('Use a three-letter currency code',
                          'أدخل رمز عملة من ثلاثة أحرف'),
            ),
            textField(_quantity, label('Quantity', 'الكمية'),
                numeric: true, validator: numericValidator),
            textField(_unitValue, label('Value per unit', 'قيمة الوحدة'),
                numeric: true, validator: numericValidator),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(label('Liability', 'التزام')),
              value: _liability,
              onChanged: (value) => setState(() => _liability = value),
            ),
          ],
        ),
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
                _AssetDraft(
                  _name.text.trim(),
                  _type.text.trim(),
                  _currency.text.trim(),
                  _number(_quantity.text)!,
                  _number(_unitValue.text)!,
                  _liability,
                ));
          },
          child: Text(label('Save', 'حفظ')),
        ),
      ],
    );
  }
}
