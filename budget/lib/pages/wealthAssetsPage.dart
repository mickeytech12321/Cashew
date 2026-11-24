import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/financialMessageParser.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:flutter/material.dart';

class WealthAssetsPage extends StatefulWidget {
  const WealthAssetsPage({super.key});

  @override
  State<WealthAssetsPage> createState() => _WealthAssetsPageState();
}

class _WealthAssetsPageState extends State<WealthAssetsPage> {
  late var _assets = database.getWealthAssets();
  bool _busy = false;
  String _valuationCurrency = 'egp';
  late var _valuation = database.getWealthValuation(_valuationCurrency);
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
          _valuation = database.getWealthValuation(_valuationCurrency);
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

  Future<void> _edit([Map<String, dynamic>? asset]) async {
    final values = await showDialog<_AssetDraft>(
      context: context,
      builder: (context) => _AssetEditor(
        asset: asset,
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
          title: Text(
              _label('Consolidated recorded value', 'إجمالي القيمة المسجّلة')),
          subtitle: snapshot.connectionState != ConnectionState.done
              ? const LinearProgressIndicator()
              : Text(value?.total != null
                  ? _amount(value!.total!, _valuationCurrency)
                  : value != null && value.missingCurrencies.isNotEmpty
                      ? '${_label('Missing exchange rates', 'أسعار الصرف غير المتاحة')} '
                          '${value.missingCurrencies.join(', ').toUpperCase()}'
                      : _label('Valuation unavailable', 'التقييم غير متاح')),
          trailing: DropdownButton<String>(
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
                      _valuation = database.getWealthValuation(value);
                    });
                  },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => PageFramework(
        title: _label('Assets and liabilities', 'الأصول والالتزامات'),
        capitalizeTitle: false,
        listWidgets: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: _busy ? null : () => _edit(),
              child: Text(_label('Add entry', 'إضافة بند')),
            ),
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
              final assets = snapshot.data!;
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
                  if (assets.isNotEmpty)
                    _valuationPanel(
                        balances.keys.map((key) => key.toLowerCase()).toSet()),
                  if (assets.isNotEmpty)
                    OutlinedButton(
                      onPressed: _busy ? null : _captureSnapshot,
                      child: Text(_label(
                          'Save valuation snapshot', 'حفظ لقطة للتقييم')),
                    ),
                  for (final balance in balances.entries)
                    ListTile(
                      title: Text(
                          _label('Net recorded value', 'صافي القيمة المسجّلة')),
                      trailing: Text(_amount(balance.value, balance.key)),
                    ),
                  for (final asset in assets)
                    ListTile(
                      title: Text(asset['name'] as String),
                      subtitle: Text(
                          _amount(_value(asset), asset['currency'] as String)),
                      leading: Icon(asset['liability'] == 1
                          ? Icons.trending_down
                          : Icons.account_balance_outlined),
                      onTap: _busy ? null : () => _edit(asset),
                      trailing: IconButton(
                        tooltip: _label('Delete entry', 'حذف البند'),
                        onPressed: _busy ? null : () => _delete(asset),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ),
                ],
              );
            },
          ),
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
                totals.update(
                    (row.currency, row.liability), (total) => total + row.value,
                    ifAbsent: () => row.value);
              }
              return ExpansionTile(
                title: Text(_label('Allocation by type', 'التوزيع حسب النوع')),
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
              return Column(
                children: [
                  ListTile(
                      title:
                          Text(_label('Valuation history', 'سجل التقييمات'))),
                  for (final entry in history)
                    ListTile(
                      title: Text(dates.formatMediumDate(entry.capturedAt)),
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
  const _AssetEditor({this.asset, required this.label});

  final Map<String, dynamic>? asset;
  final String Function(String, String) label;

  @override
  State<_AssetEditor> createState() => _AssetEditorState();
}

class _AssetEditorState extends State<_AssetEditor> {
  final _form = GlobalKey<FormState>();
  late final _name =
      TextEditingController(text: widget.asset?['name'] as String?);
  late final _type =
      TextEditingController(text: widget.asset?['asset_type'] as String?);
  late final _currency =
      TextEditingController(text: widget.asset?['currency'] as String?);
  late final _quantity =
      TextEditingController(text: widget.asset?['quantity']?.toString() ?? '1');
  late final _unitValue =
      TextEditingController(text: widget.asset?['unit_value']?.toString());
  late bool _liability = widget.asset?['liability'] == 1;

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
