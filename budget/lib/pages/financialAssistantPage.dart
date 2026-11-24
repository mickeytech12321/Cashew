import 'package:budget/database/tables.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/financialAssistant.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:flutter/material.dart';

class FinancialAssistantPage extends StatefulWidget {
  const FinancialAssistantPage({super.key});

  @override
  State<FinancialAssistantPage> createState() => _FinancialAssistantPageState();
}

class _FinancialAssistantPageState extends State<FinancialAssistantPage> {
  final _input = TextEditingController();
  late final _wallets = database.getAllWallets();
  FinancialAssistantIntent? _intent;
  TransactionWallet? _wallet;
  Future<List<Map<String, dynamic>>>? _accountTotals;

  void _interpret() {
    final intent = const FinancialAssistant().parse(_input.text);
    final spending = intent.type == FinancialAssistantIntentType.querySpending;
    setState(() {
      _intent = intent;
      _wallet = null;
      _accountTotals =
          spending || intent.type == FinancialAssistantIntentType.queryBalance
              ? database.getAssistantAccountTotals(
                  monthlySpending: spending, asOf: DateTime.now())
              : null;
    });
  }

  Widget _queryResult(bool spending) =>
      FutureBuilder<List<Map<String, dynamic>>>(
        future: _accountTotals,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Text(
                _label('Could not load totals.', 'تعذّر تحميل الإجماليات.'));
          }
          if (!snapshot.hasData) return const LinearProgressIndicator();
          if (snapshot.data!.isEmpty) {
            return Text(_label('No active accounts.', 'لا توجد حسابات نشطة.'));
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(spending
                  ? _label('Paid expenses this month by account',
                      'المصروفات المدفوعة هذا الشهر حسب الحساب')
                  : _label('Paid balance by account',
                      'رصيد المعاملات المدفوعة حسب الحساب')),
              for (final row in snapshot.data!)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(row['name'] as String),
                  trailing: Text(
                    '${((row['total'] as num) * (spending ? -1 : 1)).toStringAsFixed((row['decimals'] as int).clamp(0, 12))} '
                    '${(row['currency'] as String?)?.toUpperCase() ?? ''}',
                  ),
                ),
            ],
          );
        },
      );

  String _label(String english, String arabic) =>
      Localizations.localeOf(context).languageCode == 'ar' ? arabic : english;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final intent = _intent;
    return PageFramework(
      title: _label('Offline assistant', 'المساعد دون اتصال'),
      capitalizeTitle: false,
      listWidgets: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _input,
                maxLength: 250,
                decoration: InputDecoration(
                  labelText: _label(
                    'Ask about balances or describe a transaction',
                    'اسأل عن الرصيد أو صِف معاملة',
                  ),
                  hintText: _label('I paid 250 EGP', 'دفعت ٢٥٠ جنيه'),
                ),
                onChanged: (_) => setState(() {
                  _intent = null;
                  _wallet = null;
                  _accountTotals = null;
                }),
              ),
              FilledButton(
                onPressed: _interpret,
                child: Text(_label('Continue', 'متابعة')),
              ),
              if (_accountTotals != null)
                _queryResult(
                    intent!.type == FinancialAssistantIntentType.querySpending)
              else if (intent != null)
                _draft(intent),
            ],
          ),
        ),
      ],
    );
  }

  Widget _draft(FinancialAssistantIntent intent) {
    final income = intent.type == FinancialAssistantIntentType.addIncome;
    final amount = intent.amount;
    if ((!income && intent.type != FinancialAssistantIntentType.addExpense) ||
        amount == null ||
        !amount.isFinite ||
        amount <= 0 ||
        amount > 999999999999 ||
        intent.currency == null) {
      return Text(
        _label(
          'Enter an income or expense with an amount and currency.',
          'أدخل دخلاً أو مصروفًا مع المبلغ والعملة.',
        ),
      );
    }

    return FutureBuilder<List<TransactionWallet>>(
      future: _wallets,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Text(
            _label('Could not load accounts.', 'تعذّر تحميل الحسابات.'),
          );
        }
        if (!snapshot.hasData) return const LinearProgressIndicator();
        final wallets = snapshot.data!.where(
          (wallet) => wallet.currency?.toLowerCase() == intent.currency,
        );
        if (wallets.isEmpty) {
          return Text(
            _label(
              'Add an account in this currency to continue.',
              'أضف حسابًا بهذه العملة للمتابعة.',
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${income ? '+' : '−'}$amount ${intent.currency!.toUpperCase()}',
            ),
            DropdownButton<TransactionWallet>(
              isExpanded: true,
              hint: Text(_label('Account', 'الحساب')),
              value: _wallet,
              items: [
                for (final wallet in wallets)
                  DropdownMenuItem(value: wallet, child: Text(wallet.name)),
              ],
              onChanged: (wallet) => setState(() => _wallet = wallet),
            ),
            OutlinedButton(
              onPressed: _wallet == null
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => AddTransactionPage(
                            selectedIncome: income,
                            selectedAmount: income ? amount : -amount,
                            selectedWallet: _wallet,
                            startInitialAddTransactionSequence: false,
                            routesToPopAfterDelete: RoutesToPopAfterDelete.None,
                          ),
                        ),
                      ),
              child: Text(_label('Review transaction', 'مراجعة المعاملة')),
            ),
          ],
        );
      },
    );
  }
}
