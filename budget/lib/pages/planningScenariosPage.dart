import 'package:csv/csv.dart';
import 'package:flutter/services.dart';
import 'package:budget/pages/objectivesListPage.dart';
import 'package:budget/pages/subscriptionsPage.dart';
import 'package:budget/pages/upcomingOverdueTransactionsPage.dart';
import 'package:budget/functions.dart' show pushRoute;
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
  Set<String> _scheduledAccounts = {};
  late var _goals = database.getAllObjectives(
      objectiveType: ObjectiveType.goal, isArchived: false);
  bool _projectRecurrences = false;
  int _forecastPage = 0;
  static const _forecastPageSize = 100;

  String _forecastPreferenceKey(String scenarioPk) =>
      'planningForecastOptions.$scenarioPk';

  Future<void> _saveForecastOptions(
    Set<String> accounts,
    bool projectRecurrences,
  ) async {
    final scenario = _selected!;
    final key = _forecastPreferenceKey(scenario['scenario_pk'] as String);
    await _write(() async {
      final saved = await sharedPreferences.setStringList(
        key,
        [projectRecurrences ? '1' : '0', ...accounts],
      );
      if (!saved) throw StateError('Could not save forecast options');
      if (!mounted) return;
      _scheduledAccounts = accounts;
      _projectRecurrences = projectRecurrences;
      _select(scenario);
    });
  }

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

  Future<void> _chooseGoals(List<Objective> goals) async {
    final scenario = _selected!;
    final id = scenario['scenario_pk'] as String;
    await _write(() async {
      final selected = await database.getPlanningScenarioGoals(id);
      selected.retainAll((await _goals).map((goal) => goal.objectivePk));
      if (!mounted) return;
      final result = await showDialog<Set<String>>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) {
            return AlertDialog(
              scrollable: true,
              title: Text(
                _label('Choose goals to forecast', 'اختر الأهداف للتوقّع'),
              ),
              content: Column(
                children: [
                  for (final goal in goals)
                    CheckboxListTile(
                      title: Text(goal.name),
                      value: selected.contains(goal.objectivePk),
                      onChanged: (value) => update(() {
                        if (value == true) {
                          selected.add(goal.objectivePk);
                        } else {
                          selected.remove(goal.objectivePk);
                        }
                      }),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(_label('Cancel', 'إلغاء')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, selected),
                  child: Text(_label('Save goals', 'حفظ الأهداف')),
                ),
              ],
            );
          },
        ),
      );
      if (result == null || !mounted) return;
      await database.setPlanningScenarioGoals(id, result);
      if (mounted) _select(scenario);
    });
  }

  Future<void> _chooseAccounts(
    List<TransactionWallet> accounts,
    bool allowMultiple,
  ) async {
    final selected = {..._scheduledAccounts};
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          scrollable: true,
          title: Text(_label('Include scheduled transactions',
              'تضمين المعاملات المجدولة')),
          content: Column(
            children: [
              if (!allowMultiple)
                Text(_label('Set a scenario currency to include multiple accounts.',
                    'حدّد عملة السيناريو لتضمين أكثر من حساب.')),
              for (final account in accounts)
                CheckboxListTile(
                  title: Text(account.name),
                  subtitle: Text(account.currency?.toUpperCase() ?? ''),
                  value: selected.contains(account.walletPk),
                  onChanged: (checked) => update(() {
                    if (checked == true) {
                      if (!allowMultiple) selected.clear();
                      selected.add(account.walletPk);
                    } else {
                      selected.remove(account.walletPk);
                    }
                  }),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_label('Cancel', 'إلغاء')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected),
              child: Text(_label('Apply', 'تطبيق')),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    await _saveForecastOptions(result, _projectRecurrences);
  }

  Future<void> _openPlanningPage(Widget page) async {
    await pushRoute(context, page);
    if (!mounted) return;
    setState(() {
      _goals = database.getAllObjectives(
          objectiveType: ObjectiveType.goal, isArchived: false);
    });
    if (_selected case final scenario?) _select(scenario);
  }

  void _select(Map<String, dynamic> scenario) {
    setState(() {
      final id = scenario['scenario_pk'] as String;
      if (_selected?['scenario_pk'] != id) {
        final options = sharedPreferences.getStringList(
          _forecastPreferenceKey(id),
        );
        _scheduledAccounts = options?.skip(1).toSet() ?? {};
        _projectRecurrences = options?.firstOrNull == '1';
      }
      _forecastPage = 0;
      if (scenario['currency'] == null && _scheduledAccounts.length > 1) {
        _scheduledAccounts = {};
      }
      _selected = scenario;
      _forecast = database.calculatePlanningScenario(id,
          scheduledWalletPks: _scheduledAccounts,
          projectRecurrences: _projectRecurrences);
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
                currency: scenario['currency'] as String?,
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
        currency: draft.currency,
      );
      if (!mounted) return;
      setState(() => _scenarios = database.getPlanningScenarios());
      _select({
        'scenario_pk': scenarioPk,
        'name': draft.name,
        'base_date': draft.date.millisecondsSinceEpoch,
        'starting_balance': draft.amount,
        'horizon_days': draft.days,
        'currency': draft.currency,
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
      await sharedPreferences.remove(_forecastPreferenceKey(scenarioPk));
      if (mounted)
        setState(() {
          _scenarios = database.getPlanningScenarios();
          _selected = null;
          _forecast = null;
          _items = null;
        });
    });
  }

  Future<void> _copyForecast(
    List<Map<String, dynamic>> points,
    String? currency,
  ) async {
    final csv = const ListToCsvConverter().convert([
      ['date', 'currency', 'type', 'amount', 'balance'],
      for (final point in points)
        [
          (point['date'] as DateTime).toIso8601String(),
          currency ?? '',
          point['item_pk'] == null ? 'opening'
              : point['goal'] == true ? 'goal'
              : point['projected'] == true ? 'recurrence'
              : point['scheduled'] == true ? 'scheduled' : 'manual',
          point['amount'],
          point['balance'],
        ],
    ]);
    try {
      await Clipboard.setData(ClipboardData(text: csv));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
          _label('Forecast copied as CSV.', 'تم نسخ التوقع بصيغة CSV.'),
        )));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
          _label('Could not copy forecast.', 'تعذّر نسخ التوقع.'),
        )));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedPk = _selected?['scenario_pk'] as String?;
    final currency = (_selected?['currency'] as String?)?.toUpperCase();
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
              Wrap(
                children: [
                  TextButton(
                    onPressed: _busy ? null : () => _openPlanningPage(
                      const UpcomingOverdueTransactions(overdueTransactions: null),
                    ),
                    child: Text(_label('Bills', 'الفواتير')),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => _openPlanningPage(
                      const SubscriptionsPage(),
                    ),
                    child: Text(_label('Subscriptions', 'الاشتراكات')),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => _openPlanningPage(
                      const ObjectivesListPage(backButton: true),
                    ),
                    child: Text(_label('Goals', 'الأهداف')),
                  ),
                ],
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
                  currency == null
                      ? 'Use one currency for all amounts in this scenario.'
                      : 'Manual amounts are in $currency.',
                  currency == null
                      ? 'استخدم عملة واحدة لجميع المبالغ في هذا السيناريو.'
                      : 'المبالغ اليدوية بعملة $currency.',
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
                    final accounts = snapshot.data!;
                    if (accounts.isEmpty) return const SizedBox.shrink();
                    return OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _chooseAccounts(accounts, currency != null),
                      child: Text(_label(
                        'Scheduled accounts (${_scheduledAccounts.length})',
                        'الحسابات المجدولة (${_scheduledAccounts.length})',
                      )),
                    );
                  },
                ),
              if (currency != null)
                FutureBuilder<List<Objective>>(
                  future: _goals,
                  builder: (context, snapshot) {
                    if (snapshot.hasError)
                      return Text(_label(
                          'Could not load goals.', 'تعذّر تحميل الأهداف.'));
                    if (!snapshot.hasData)
                      return const LinearProgressIndicator();
                    final base = _asDate(_selected!['base_date']);
                    final days = _selected!['horizon_days'] as int;
                    final end = DateTime(
                        base.year,
                        base.month,
                        base.day + days,
                        base.hour,
                        base.minute,
                        base.second,
                        base.millisecond,
                        base.microsecond);
                    final goals = snapshot.data!
                        .where((goal) =>
                            goal.endDate != null &&
                            !goal.endDate!.isBefore(base) &&
                            !goal.endDate!.isAfter(end))
                        .toList();
                    if (goals.isEmpty) return const SizedBox.shrink();
                    return OutlinedButton(
                      onPressed: _busy ? null : () => _chooseGoals(goals),
                      child: Text(_label('Choose goals to forecast', 'اختر الأهداف للتوقّع')),
                    );
                  },
                ),
              if (_selected != null && _scheduledAccounts.isNotEmpty)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_label('Project future recurring entries',
                      'توقّع البنود المتكررة القادمة')),
                  value: _projectRecurrences,
                  onChanged: _busy
                      ? null
                      : (value) =>
                          _saveForecastOptions(_scheduledAccounts, value),
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
              if (snapshot.connectionState != ConnectionState.done) {
                return const LinearProgressIndicator();
              }
              final error = snapshot.error;
              if (error is PlanningRateUnavailable) {
                final source = error.source?.toUpperCase() ?? '—';
                final target = error.target.toUpperCase();
                return ListTile(
                    title: Text(_label(
                  'Exchange rate unavailable for $source to $target.',
                  'سعر الصرف من $source إلى $target غير متاح.',
                )));
              }
              if (snapshot.hasError) {
                return ListTile(
                    title: Text(_label('Could not calculate the forecast.',
                        'تعذّر حساب التوقّع.')));
              }
              if (!snapshot.hasData) return const LinearProgressIndicator();
              final points = snapshot.data!;
              final lowest = points.reduce((a, b) =>
                  (a['balance'] as num) <= (b['balance'] as num) ? a : b);
              final shortfall = points.where((point) =>
                  (point['balance'] as num) < 0).firstOrNull;
              String balanceAt(Map<String, dynamic> point) =>
                  '${(point['balance'] as num).toStringAsFixed(2)} ${currency ?? ''}'
                      .trim();
              final start = _forecastPage * _forecastPageSize;
              final visible = points.skip(start).take(_forecastPageSize);
              final end = start + visible.length;
              return Column(
                children: [
                  TextButton.icon(
                    onPressed: () => _copyForecast(points, currency),
                    icon: const Icon(Icons.copy_outlined),
                    label: Text(_label('Copy forecast as CSV', 'نسخ التوقع بصيغة CSV')),
                  ),
                  ListTile(
                    title: Text(_label('Projected ending balance',
                        'الرصيد المتوقع في نهاية الفترة')),
                    trailing: Text(balanceAt(points.last)),
                  ),
                  ListTile(
                    title: Text(_label('Lowest projected balance',
                        'أقل رصيد متوقع')),
                    subtitle: Text(dates.formatMediumDate(lowest['date'] as DateTime)),
                    trailing: Text(balanceAt(lowest)),
                  ),
                  if (shortfall != null)
                    ListTile(
                      title: Text(_label('First projected shortfall',
                          'أول عجز متوقع')),
                      subtitle: Text(dates.formatMediumDate(shortfall['date'] as DateTime)),
                      trailing: Text(balanceAt(shortfall)),
                    ),
                  if (points.length > _forecastPageSize)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          TextButton(
                            onPressed: start == 0 ? null
                                : () => setState(() => _forecastPage--),
                            child: Text(_label('Previous', 'السابق')),
                          ),
                          Text(_label('${start + 1}–$end of ${points.length}',
                              '${start + 1}–$end من ${points.length}')),
                          TextButton(
                            onPressed: end == points.length ? null
                                : () => setState(() => _forecastPage++),
                            child: Text(_label('Next', 'التالي')),
                          ),
                        ],
                      ),
                    ),
                  for (final point in visible)
                    ListTile(
                      title: Text(point['name'] as String? ??
                          _label('Starting balance', 'الرصيد الافتتاحي')),
                      subtitle: Text([
                        dates.formatMediumDate(point['date'] as DateTime),
                        if (point['goal'] == true)
                          _label(
                              'Remaining goal amount', 'المبلغ المتبقي للهدف')
                        else if (point['projected'] == true)
                          _label('Projected recurrence', 'تكرار متوقع')
                        else if (point['scheduled'] == true)
                          _label('Scheduled', 'مجدولة'),
                      ].join(' · ')),
                      trailing:
                          Text((point['balance'] as num).toStringAsFixed(2)),
                    ),
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
      this.name, this.amount, this.date, this.days, this.income,
      {this.currency});
  final String name;
  final double amount;
  final DateTime date;
  final int? days;
  final bool income;
  final String? currency;
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
  late final _currency =
      TextEditingController(text: widget.draft?.currency?.toUpperCase());
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
    _currency.dispose();
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
            if (scenario)
              TextFormField(
                controller: _currency,
                readOnly: widget.draft?.currency != null,
                maxLength: 3,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: label('Currency code', 'رمز العملة'),
                  helperText: widget.draft == null
                      ? null
                      : label('Existing amounts use this currency.',
                          'المبالغ الحالية تستخدم هذه العملة.'),
                ),
                validator: (value) {
                  final code = value?.trim() ?? '';
                  if (code.isEmpty && widget.draft != null) return null;
                  return RegExp(r'^[a-zA-Z]{3}$').hasMatch(code)
                      ? null
                      : label('Enter a three-letter code',
                          'أدخل رمزًا من ثلاثة أحرف');
                },
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
                  currency: !scenario || _currency.text.trim().isEmpty
                      ? null
                      : _currency.text.trim().toLowerCase(),
                ));
          },
          child: Text(label('Save', 'حفظ')),
        ),
      ],
    );
  }
}
