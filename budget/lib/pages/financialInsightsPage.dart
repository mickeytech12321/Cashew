import 'package:budget/widgets/util/monthlySpendingWidget.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:flutter/material.dart';

class FinancialInsightsPage extends StatefulWidget {
  const FinancialInsightsPage({super.key});

  @override
  State<FinancialInsightsPage> createState() => _FinancialInsightsPageState();
}

class _FinancialInsightsPageState extends State<FinancialInsightsPage> {
  int _monthsBack = 0;
  String? _account;
  late final _accounts = database.getFinancialInsightsAccounts();
  late var _insights = _load();

  String _label(String english, String arabic) =>
      Localizations.localeOf(context).languageCode == 'ar' ? arabic : english;

  DateTime _month(DateTime today, int offset) =>
      DateTime(today.year, today.month - offset);

  Future<
      List<
          ({
            String currency,
            String? category,
            double income,
            double expenses
          })>> _load() {
    final today = DateTime.now();
    return database.getFinancialInsights(
      _month(today, _monthsBack),
      _monthsBack == 0
          ? DateTime(today.year, today.month, today.day + 1)
          : _month(today, _monthsBack - 1),
      walletPk: _account,
    );
  }

  String _amount(double value, String code) =>
      '${value.toStringAsFixed(2)} ${code.toUpperCase()}'.trim();

  @override
  Widget build(BuildContext context) => PageFramework(
        title: _label('Financial insights', 'التحليلات المالية'),
        capitalizeTitle: false,
        listWidgets: [
          if (supportsMonthlySpendingWidget)
            ValueListenableBuilder<bool>(
              valueListenable: monthlySpendingWidgetEnabled,
              builder: (context, enabled, _) => SwitchListTile(
                title: Text(_label('Show spending on Android home screen', 'عرض المصروفات على شاشة أندرويد الرئيسية')),
                subtitle: Text(_label('Add the Monthly spending widget in your launcher.',
                    'أضف ويدجت مصروفات الشهر من إعدادات الشاشة الرئيسية.')),
                value: enabled,
                onChanged: (value) async {
                  try {
                    await setMonthlySpendingVisibility(value);
                  } catch (_) {
                    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(_label('Could not update the widget.', 'تعذّر تحديث الويدجت.'))),
                    );
                  }
                },
              ),
            ),
          FutureBuilder(
            future: _accounts,
            builder: (context, snapshot) {
              final accounts = snapshot.data;
              if (accounts == null || accounts.length < 2) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _account,
                  hint: Text(_label('All active accounts', 'كل الحسابات النشطة')),
                  items: [
                    DropdownMenuItem<String>(
                      child: Text(_label(
                          'All active accounts', 'كل الحسابات النشطة')),
                    ),
                    for (final account in accounts)
                      DropdownMenuItem(
                        value: account.id,
                        child: Text(
                          '${account.name} · ${account.currency.toUpperCase()}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() {
                    _account = value;
                    _insights = _load();
                  }),
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButton<int>(
              isExpanded: true,
              value: _monthsBack,
              items: [
                for (var offset = 0; offset < 12; offset++)
                  DropdownMenuItem(
                    value: offset,
                    child:
                        Text(MaterialLocalizations.of(context).formatMonthYear(
                      _month(DateTime.now(), offset),
                    )),
                  ),
              ],
              onChanged: (value) {
                if (value != null)
                  setState(() {
                    _monthsBack = value;
                    _insights = _load();
                  });
              },
            ),
          ),
          FutureBuilder(
            future: _insights,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const LinearProgressIndicator();
              }
              if (snapshot.hasError)
                return ListTile(
                    title: Text(
                  _label('Could not load insights.', 'تعذّر تحميل التحليلات.'),
                ));
              final rows = snapshot.data!;
              if (rows.isEmpty)
                return ListTile(
                    title: Text(
                  _label('No paid income or expenses in this period.',
                      'لا توجد إيرادات أو مصروفات مدفوعة خلال هذه الفترة.'),
                ));
              final currencies = rows.map((row) => row.currency).toSet();
              return Column(
                children: [
                  for (final currency in currencies)
                    Builder(builder: (context) {
                      final entries =
                          rows.where((row) => row.currency == currency);
                      final income =
                          entries.fold(0.0, (sum, row) => sum + row.income);
                      final expense =
                          entries.fold(0.0, (sum, row) => sum + row.expenses);
                      return ExpansionTile(
                        key: PageStorageKey(('insight', _account, _monthsBack, currency)),
                        initiallyExpanded: true,
                        title: Text(currency.isEmpty
                            ? _label('Currency unspecified', 'العملة غير محددة')
                            : currency.toUpperCase()),
                        subtitle: Text([
                          '${_label('Income', 'الإيرادات')} ${_amount(income, currency)}',
                          '${_label('Expenses', 'المصروفات')} ${_amount(expense, currency)}',
                          '${_label('Net cash flow', 'صافي التدفق النقدي')} ${_amount(income - expense, currency)}',
                        ].join('\n')),
                        children: [
                          for (final entry
                              in entries.where((row) => row.expenses > 0))
                            ListTile(
                              title: Text(entry.category ??
                                  _label('Uncategorized', 'بدون تصنيف')),
                              trailing: Text(_amount(entry.expenses, currency)),
                            ),
                        ],
                      );
                    }),
                ],
              );
            },
          ),
        ],
      );
}
