import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/financialMessageParser.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:flutter/material.dart';

class PlanningScenariosPage extends StatefulWidget {
  const PlanningScenariosPage({super.key});

  @override
  State<PlanningScenariosPage> createState() => _PlanningScenariosPageState();
}

class _PlanningScenariosPageState extends State<PlanningScenariosPage> {
  late var _scenarios = database.getPlanningScenarios();
  Future<List<Map<String, dynamic>>>? _forecast;
  Future<List<Map<String, dynamic>>>? _items;
  Map<String, dynamic>? _selected;
  bool _busy = false;
  late final _wallets = database.getAllWallets();
  String? _scheduledWalletPk;

  String _label(String english, String arabic) =>
      Localizations.localeOf(context).languageCode == 'ar' ? arabic : english;

  DateTime _asDate(Object? value) =>
      DateTime.fromMillisecondsSinceEpoch(value as int);

  Future<void> _write(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
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

  void _select(Map<String, dynamic> scenario) {
    setState(() {
      if (_selected?['scenario_pk'] != scenario['scenario_pk']) {
        _scheduledWalletPk = null;
      }
      _selected = scenario;
      final id = scenario['scenario_pk'] as String;
      _forecast = database.calculatePlanningScenario(id,
          scheduledWalletPk: _scheduledWalletPk);
      _items = database.getPlanningScenarioItems(id);
    });
  }

  Future<void> _editScenario([Map<String, dynamic>? scenario]) async {
    final draft = await showDialog<_PlanningDraft>(
      context: context,
      builder: (_) => _PlanningEditor(
        label: _label,
        scenario: true,
        draft: scenario == null
            ? null
            : _PlanningDraft(
                scenario['name'] as String,
                (scenario['starting_balance'] as num).toDouble(),
                _asDate(scenario['base_date']),
                scenario['horizon_days'] as int,
                false,
              ),
      ),
    );
    if (draft == null || !mounted) return;
    final scenarioPk = scenario?['scenario_pk'] as String? ?? uuid.v4();
    await _write(() async {
      await database.savePlanningScenario(
        scenarioPk: scenarioPk,
        name: draft.name,
        baseDate: draft.date,
        horizonDays: draft.days!,
        startingBalance: draft.amount,
      );
      if (!mounted) return;
      setState(() => _scenarios = database.getPlanningScenarios());
      _select({
        'scenario_pk': scenarioPk,
        'name': draft.name,
        'base_date': draft.date.millisecondsSinceEpoch,
        'starting_balance': draft.amount,
        'horizon_days': draft.days,
      });
    });
  }

  Future<void> _editItem([Map<String, dynamic>? item]) async {
    final current = _selected!;
    final draft = await showDialog<_PlanningDraft>(
      context: context,
      builder: (_) => _PlanningEditor(
        label: _label,
        scenario: false,
        initialDate: _asDate(current['base_date']),
        draft: item == null
            ? null
            : _PlanningDraft(
                item['name'] as String,
                (item['amount'] as num).toDouble(),
                _asDate(item['first_date']),
                item['recurrence_days'] as int?,
                item['direction'] == 'income',
              ),
      ),
    );
    if (draft == null || !mounted) return;
    await _write(() async {
      await database.savePlanningScenarioItem(
        itemPk: item?['item_pk'] as String? ?? uuid.v4(),
        scenarioPk: current['scenario_pk'] as String,
        name: draft.name,
        amount: draft.amount,
        income: draft.income,
        firstDate: draft.date,
        recurrenceDays: draft.days,
        endDate: item?['end_date'] == null ? null : _asDate(item!['end_date']),
      );
      if (mounted) _select(current);
    });
  }

  Future<void> _delete([Map<String, dynamic>? item]) async {
    final scenario = _selected!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item == null
            ? _label(
                'Delete scenario and its entries?', 'حذف السيناريو وبنوده؟')
            : _label('Delete entry?', 'حذف البند؟')),
        content: Text((item ?? scenario)['name'] as String),
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
    if (confirmed != true || !mounted) return;
    final scenarioPk = scenario['scenario_pk'] as String;
    await _write(() async {
      if (item != null) {
        await database.deletePlanningScenarioItem(
            scenarioPk, item['item_pk'] as String);
        if (mounted) _select(scenario);
        return;
      }
      await database.deletePlanningScenario(scenarioPk);
      if (mounted)
        setState(() {
          _scenarios = database.getPlanningScenarios();
          _selected = null;
          _forecast = null;
          _items = null;
        });
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedPk = _selected?['scenario_pk'] as String?;
    final dates = MaterialLocalizations.of(context);
    return PageFramework(
      title: _label('Cash-flow scenarios', 'سيناريوهات التدفق النقدي'),
      capitalizeTitle: false,
      listWidgets: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                onPressed: _busy ? null : () => _editScenario(),
                child: Text(_label('New scenario', 'سيناريو جديد')),
              ),
              FutureBuilder<List<Map<String, dynamic>>>(
                future: _scenarios,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Text(_label('Could not load scenarios.',
                        'تعذّر تحميل السيناريوهات.'));
                  }
                  if (!snapshot.hasData) return const LinearProgressIndicator();
                  final scenarios = snapshot.data!;
                  return DropdownButton<String>(
                    isExpanded: true,
                    value: scenarios.any(
                            (scenario) => scenario['scenario_pk'] == selectedPk)
                        ? selectedPk
                        : null,
                    hint: Text(_label('Select a scenario', 'اختر سيناريو')),
                    items: [
                      for (final scenario in scenarios)
                        DropdownMenuItem(
                          value: scenario['scenario_pk'] as String,
                          child: Text(scenario['name'] as String),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) {
                            if (value != null) {
                              _select(scenarios.firstWhere(
                                  (row) => row['scenario_pk'] == value));
                            }
                          },
                  );
                },
              ),
              if (_selected != null)
                Text(_label(
                  'Use one currency for all amounts in this scenario.',
                  'استخدم عملة واحدة لجميع المبالغ في هذا السيناريو.',
                )),
              if (_selected != null)
                FutureBuilder<List<TransactionWallet>>(
                  future: _wallets,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Text(_label(
                          'Could not load accounts.', 'تعذّر تحميل الحسابات.'));
                    }
                    if (!snapshot.hasData)
                      return const LinearProgressIndicator();
                    return DropdownButton<String>(
                      isExpanded: true,
                      value: _scheduledWalletPk ?? '',
                      items: [
                        DropdownMenuItem(
                          value: '',
                          child: Text(_label('Exclude scheduled transactions',
                              'استبعاد المعاملات المجدولة')),
                        ),
                        for (final wallet in snapshot.data!)
                          DropdownMenuItem(
                            value: wallet.walletPk,
                            child: Text(
                                _label(
                                  'Include scheduled from ${wallet.name} (${wallet.currency?.toUpperCase() ?? ''})',
                                  'تضمين المعاملات المجدولة من ${wallet.name} (${wallet.currency?.toUpperCase() ?? ''})',
                                ),
                                overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: _busy
                          ? null
                          : (value) {
                              _scheduledWalletPk = value == '' ? null : value;
                              _select(_selected!);
                            },
                    );
                  },
                ),
              if (_selected != null)
                Wrap(children: [
                  TextButton(
                    onPressed: _busy ? null : () => _editScenario(_selected),
                    child: Text(_label('Edit scenario', 'تعديل السيناريو')),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => _delete(),
                    child: Text(_label('Delete scenario', 'حذف السيناريو')),
                  ),
                ]),
              if (_selected != null)
                OutlinedButton(
                  onPressed: _busy ? null : () => _editItem(),
                  child: Text(
                      _label('Add income or expense', 'إضافة دخل أو مصروف')),
                ),
            ],
          ),
        ),
        if (_items != null)
          FutureBuilder<List<Map<String, dynamic>>>(
            key: ValueKey(('items', selectedPk)),
            future: _items,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return ListTile(
                    title: Text(_label(
                        'Could not load entries.', 'تعذّر تحميل البنود.')));
              }
              if (!snapshot.hasData) return const LinearProgressIndicator();
              return Column(children: [
                for (final item in snapshot.data!)
                  ListTile(
                    title: Text(item['name'] as String),
                    subtitle: Text(
                        dates.formatMediumDate(_asDate(item['first_date']))),
                    onTap: _busy ? null : () => _editItem(item),
                    trailing: IconButton(
                      tooltip: _label('Delete entry', 'حذف البند'),
                      onPressed: _busy ? null : () => _delete(item),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ),
              ]);
            },
          ),
        if (_forecast != null)
          FutureBuilder<List<Map<String, dynamic>>>(
            key: ValueKey(('forecast', selectedPk)),
            future: _forecast,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return ListTile(
                    title: Text(_label('Could not calculate the forecast.',
                        'تعذّر حساب التوقّع.')));
              }
              if (!snapshot.hasData) return const LinearProgressIndicator();
              final points = snapshot.data!;
              // Render a bounded preview while keeping the calculation horizon intact.
              const visibleCount = 100;
              return Column(
                children: [
                  ListTile(
                    title: Text(_label('Projected ending balance',
                        'الرصيد المتوقع في نهاية الفترة')),
                    trailing: Text(
                        (points.last['balance'] as num).toStringAsFixed(2)),
                  ),
                  for (final point in points.take(visibleCount))
                    ListTile(
                      title: Text(point['name'] as String? ??
                          _label('Starting balance', 'الرصيد الافتتاحي')),
                      subtitle: Text([
                        dates.formatMediumDate(point['date'] as DateTime),
                        if (point['scheduled'] == true)
                          _label('Scheduled', 'مجدولة'),
                      ].join(' · ')),
                      trailing:
                          Text((point['balance'] as num).toStringAsFixed(2)),
                    ),
                  if (points.length > visibleCount)
                    ListTile(
                        title: Text(_label('Showing the first 100 entries.',
                            'يتم عرض أول ١٠٠ بند.'))),
                ],
              );
            },
          ),
      ],
    );
  }
}

class _PlanningDraft {
  const _PlanningDraft(
      this.name, this.amount, this.date, this.days, this.income);
  final String name;
  final double amount;
  final DateTime date;
  final int? days;
  final bool income;
}

class _PlanningEditor extends StatefulWidget {
  const _PlanningEditor(
      {required this.label,
      required this.scenario,
      this.initialDate,
      this.draft});
  final String Function(String, String) label;
  final bool scenario;
  final DateTime? initialDate;
  final _PlanningDraft? draft;

  @override
  State<_PlanningEditor> createState() => _PlanningEditorState();
}

class _PlanningEditorState extends State<_PlanningEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.draft?.name);
  late final _amount = TextEditingController(
      text: widget.draft?.amount.toString() ?? (widget.scenario ? '0' : ''));
  late final _days = TextEditingController(
      text: widget.draft?.days?.toString() ?? (widget.scenario ? '30' : ''));
  late DateTime _date = widget.draft?.date ??
      widget.initialDate ??
      DateUtils.dateOnly(DateTime.now());
  late bool _income = widget.draft?.income ?? false;

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _days.dispose();
    super.dispose();
  }

  String _normalize(String? input) =>
      FinancialMessageParser.normalize(input?.trim() ?? '');

  @override
  Widget build(BuildContext context) {
    final label = widget.label;
    final scenario = widget.scenario;
    return AlertDialog(
      title: Text(widget.draft != null
          ? (scenario
              ? label('Edit scenario', 'تعديل السيناريو')
              : label('Edit entry', 'تعديل البند'))
          : scenario
              ? label('New scenario', 'سيناريو جديد')
              : label('Add income or expense', 'إضافة دخل أو مصروف')),
      scrollable: true,
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _name,
              maxLength: 100,
              decoration: InputDecoration(labelText: label('Name', 'الاسم')),
              validator: (value) => value?.trim().isNotEmpty == true
                  ? null
                  : label('Required', 'مطلوب'),
            ),
            TextFormField(
              controller: _amount,
              decoration: InputDecoration(
                  labelText: scenario
                      ? label('Starting balance', 'الرصيد الافتتاحي')
                      : label('Amount', 'المبلغ')),
              keyboardType: TextInputType.numberWithOptions(
                  decimal: true, signed: scenario),
              validator: (input) {
                final value = double.tryParse(_normalize(input));
                return value != null &&
                        value.isFinite &&
                        value.abs() <= 999999999999 &&
                        (scenario || value > 0)
                    ? null
                    : label('Enter a valid amount', 'أدخل مبلغًا صالحًا');
              },
            ),
            TextFormField(
              controller: _days,
              decoration: InputDecoration(
                  labelText: scenario
                      ? label('Forecast days', 'عدد أيام التوقع')
                      : label('Repeat every N days (optional)',
                          'التكرار كل عدد من الأيام (اختياري)')),
              keyboardType: TextInputType.number,
              validator: (input) {
                final text = _normalize(input);
                if (!scenario && text.isEmpty) return null;
                final days = int.tryParse(text);
                return days != null && days >= 1 && days <= 3650
                    ? null
                    : label('Enter 1 to 3650 days', 'أدخل من ١ إلى ٣٦٥٠ يومًا');
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(scenario
                  ? label('Base date', 'تاريخ البداية')
                  : label('First occurrence', 'أول موعد')),
              subtitle: Text(
                  MaterialLocalizations.of(context).formatMediumDate(_date)),
              trailing: const Icon(Icons.calendar_today_outlined),
              onTap: () async {
                final result = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime(1900),
                  lastDate: DateTime(2300),
                );
                if (mounted && result != null) setState(() => _date = result);
              },
            ),
            if (!scenario)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(label('Income', 'دخل')),
                value: _income,
                onChanged: (value) => setState(() => _income = value),
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
                _PlanningDraft(
                  _name.text.trim(),
                  double.parse(_normalize(_amount.text)),
                  _date,
                  int.tryParse(_normalize(_days.text)),
                  _income,
                ));
          },
          child: Text(label('Save', 'حفظ')),
        ),
      ],
    );
  }
}
