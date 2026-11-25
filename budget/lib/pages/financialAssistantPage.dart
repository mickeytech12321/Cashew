import 'package:budget/widgets/cashuSurfaces.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/pages/addWalletPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/financialAssistant.dart';
import 'package:budget/struct/openAiFinancialAssistant.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

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

  static const _speech = MethodChannel('cashew/assistant_speech');
  late final Future<bool> _voiceAvailable = _supportsVoice();
  bool _listening = false;
  bool _requestingAi = false;
  bool _aiSuggested = false;
  String? _sessionKey;
  static const _apiKey = MethodChannel('cashew/assistant_key');

  bool get _canStoreApiKey =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<String?> _readApiKey() async => _canStoreApiKey
      ? await _apiKey.invokeMethod<String>('read')
      : _sessionKey;

  void _assistantMessage(String english, String arabic) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_label(english, arabic))),
    );
  }

  Future<void> _editAiSettings() async {
    var hasKey = false;
    try {
      hasKey = (await _readApiKey()) != null;
    } catch (_) {
      // The settings dialog still allows clearing or replacing an unreadable key.
    }
    if (!mounted) return;
    var replacement = '';
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title:
            Text(_label('Optional OpenAI assistant', 'مساعد OpenAI الاختياري')),
        scrollable: true,
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_canStoreApiKey
              ? _label(
                  'Your API key is protected by Android Keystore on this device.',
                  'يحمي Android Keystore مفتاح API على هذا الجهاز.')
              : _label(
                  'Your API key stays in memory until you leave this screen.',
                  'يبقى مفتاح API في الذاكرة حتى تغادر هذه الشاشة.')),
          TextField(
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            maxLength: 300,
            textDirection: TextDirection.ltr,
            onChanged: (value) => replacement = value.trim(),
            decoration: InputDecoration(
              labelText: _label('OpenAI API key', 'مفتاح OpenAI API'),
              helperText: hasKey
                  ? _label('A key is configured.', 'تم إعداد مفتاح.')
                  : null,
            ),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_label('Cancel', 'إلغاء')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: Text(_label('Remove key', 'حذف المفتاح')),
          ),
          FilledButton(
            onPressed: () {
              if (RegExp(r'^[A-Za-z0-9_-]{12,300}$').hasMatch(replacement)) {
                Navigator.pop(context, replacement);
              } else {
                _assistantMessage(
                    'Enter a valid API key.', 'أدخل مفتاح API صالحًا.');
              }
            },
            child: Text(_label('Save', 'حفظ')),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    try {
      if (_canStoreApiKey) {
        await _apiKey.invokeMethod<void>(
            choice.isEmpty ? 'clear' : 'save', choice.isEmpty ? null : choice);
      } else {
        _sessionKey = choice.isEmpty ? null : choice;
      }
      _assistantMessage(
        choice.isEmpty ? 'API key removed.' : 'API key saved.',
        choice.isEmpty ? 'تم حذف مفتاح API.' : 'تم حفظ مفتاح API.',
      );
    } catch (_) {
      _assistantMessage(
          'Could not update the protected key.', 'تعذّر تحديث المفتاح المحمي.');
    }
  }

  Future<void> _interpretOnline() async {
    if (_requestingAi || _listening) return;
    final command = _input.text.trim();
    if (command.isEmpty) {
      _assistantMessage('Enter a command to continue.', 'أدخل طلبًا للمتابعة.');
      return;
    }
    setState(() => _requestingAi = true);
    http.Client? client;
    try {
      final key = await _readApiKey();
      if (!mounted) return;
      if (key == null) {
        _assistantMessage('Add an API key in AI settings first.',
            'أضف مفتاح API من إعدادات الذكاء الاصطناعي أولًا.');
        return;
      }
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_label(
              'Send this text to OpenAI?', 'إرسال هذا النص إلى OpenAI؟')),
          scrollable: true,
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_label(
              'OpenAI receives the text below and your API key. Usage may incur API charges.',
              'تستقبل OpenAI النص أدناه ومفتاح API. قد تُحتسب رسوم لاستخدام الخدمة.',
            )),
            const SizedBox(height: 12),
            SelectableText(command),
          ]),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(_label('Cancel', 'إلغاء')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(_label('Send text', 'إرسال النص')),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted || _input.text.trim() != command) return;
      client = http.Client();
      final suggestion = await OpenAiFinancialAssistant(client, key)
          .interpret(command)
          .timeout(const Duration(seconds: 30));
      if (mounted && _input.text.trim() == command) {
        _applyIntent(suggestion, aiSuggested: true);
      }
    } catch (_) {
      _assistantMessage(
          'OpenAI could not interpret this request. You can continue offline.',
          'تعذّر تفسير الطلب باستخدام OpenAI. يمكنك المتابعة دون اتصال.');
    } finally {
      client?.close();
      if (mounted) setState(() => _requestingAi = false);
    }
  }

  Future<bool> _supportsVoice() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await _speech.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _cancelVoice() async {
    try {
      await _speech.invokeMethod<void>('cancel');
    } catch (_) {
      // The screen may already have closed with the platform session.
    }
  }

  Future<void> _dictate() async {
    if (_listening) {
      await _cancelVoice();
      return;
    }
    setState(() => _listening = true);
    try {
      final text = await _speech.invokeMethod<String>('listen', {
        'language': Localizations.localeOf(context).languageCode,
      });
      if (!mounted || text == null) return;
      final limited = String.fromCharCodes(text.runes.take(250));
      setState(() {
        _input.text = limited;
        _input.selection = TextSelection.collapsed(offset: limited.length);
        _intent = null;
        _wallet = null;
        _accountTotals = null;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      final message = switch (error.code) {
        'permission' => _label('Allow microphone access to dictate.',
            'اسمح بالميكروفون للإملاء الصوتي.'),
        'language' => _label(
            'Offline recognition is unavailable for this language.',
            'التعرّف دون اتصال غير متاح لهذه اللغة.'),
        _ => _label(
            'Could not recognize speech. Try again or type your request.',
            'تعذّر التعرّف على الكلام. حاول مرة أخرى أو اكتب طلبك.'),
      };
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _listening = false);
    }
  }

  void _interpret() =>
      _applyIntent(const FinancialAssistant().parse(_input.text));

  void _applyIntent(FinancialAssistantIntent intent,
      {bool aiSuggested = false}) {
    final spending = intent.type == FinancialAssistantIntentType.querySpending;
    final now = DateTime.now();
    final period = intent.spendingPeriod.range(now);
    setState(() {
      _intent = intent;
      _aiSuggested = aiSuggested;
      _wallet = null;
      _accountTotals =
          spending || intent.type == FinancialAssistantIntentType.queryBalance
              ? database.getAssistantAccountTotals(
                  monthlySpending: spending,
                  asOf: now,
                  spendingStart: period.start,
                  spendingEnd: period.end)
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
                  ? _label('Paid expenses by account',
                      'المصروفات المدفوعة حسب الحساب')
                  : _label('Paid balance by account',
                      'رصيد المعاملات المدفوعة حسب الحساب')),
              if (spending)
                Text(switch (_intent!.spendingPeriod) {
                  SpendingPeriod.currentWeek =>
                    _label('This week', 'هذا الأسبوع'),
                  SpendingPeriod.previousWeek =>
                    _label('Last week', 'الأسبوع الماضي'),
                  SpendingPeriod.currentMonth =>
                    _label('This month', 'هذا الشهر'),
                  SpendingPeriod.previousMonth =>
                    _label('Last month', 'الشهر الماضي'),
                  SpendingPeriod.currentYear =>
                    _label('This year', 'هذا العام'),
                }),
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
    if (_listening) _cancelVoice();
    _input.dispose();
    super.dispose();
  }

  void _quickQuery(String question, FinancialAssistantIntentType type,
      SpendingPeriod period) {
    _input.text = question;
    _applyIntent(FinancialAssistantIntent(
      type: type,
      rawText: question,
      requiresConfirmation: false,
      spendingPeriod: period,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final intent = _intent;
    final colors = CashuColors(context);
    final busy = _listening || _requestingAi;
    return PageFramework(
      title: _label('Offline assistant', 'المساعد دون اتصال'),
      backgroundColor: colors.canvas,
      horizontalPaddingConstrained: true,
      capitalizeTitle: false,
      listWidgets: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CashuGreenPanel(
                child: Row(children: [
                  const Icon(Icons.auto_awesome_outlined,
                      color: Color(0xffb4edb8), size: 28),
                  const SizedBox(width: 12),
                  Flexible(
                      child: Text(
                          _label('Get a quick account summary',
                              'اعرف ملخّص حساباتك'),
                          style: const TextStyle(
                              color: Color(0xffeff8f0),
                              fontWeight: FontWeight.w800,
                              fontSize: 18))),
                ]),
              ),
              const SizedBox(height: 10),
              CashuPanel(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (final (icon, text, type, period) in [
                      (
                        Icons.account_balance_wallet_outlined,
                        _label('Current balances', 'الأرصدة الحالية'),
                        FinancialAssistantIntentType.queryBalance,
                        SpendingPeriod.currentMonth
                      ),
                      (
                        Icons.calendar_today_outlined,
                        _label('Spending this month', 'مصروفات الشهر ده'),
                        FinancialAssistantIntentType.querySpending,
                        SpendingPeriod.currentMonth
                      ),
                      (
                        Icons.history_rounded,
                        _label('Spending last month', 'مصروفات الشهر اللي فات'),
                        FinancialAssistantIntentType.querySpending,
                        SpendingPeriod.previousMonth
                      ),
                    ])
                      CashuActionRow(
                          icon: icon,
                          title: text,
                          onTap: busy
                              ? null
                              : () => _quickQuery(text, type, period)),
                  ],
                ),
              ),
              if (_requestingAi) const LinearProgressIndicator(),
              if (intent != null) ...[
                CashuSectionTitle(_aiSuggested
                    ? _label('OpenAI suggestion', 'اقتراح OpenAI')
                    : _label('Result', 'النتيجة')),
                CashuPanel(
                  child: _accountTotals != null
                      ? _queryResult(intent.type ==
                          FinancialAssistantIntentType.querySpending)
                      : _draft(intent),
                ),
              ],
              CashuSectionTitle(
                  _label('Ask or record a transaction', 'اسأل أو سجّل معاملة')),
              CashuPanel(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _input,
                        enabled: !_requestingAi,
                        maxLength: 250,
                        textInputAction: TextInputAction.go,
                        decoration: cashuInput(
                            context,
                            _label(
                                'e.g. I paid 250 EGP', 'مثال: دفعت ٢٥٠ جنيه')),
                        onSubmitted: busy ? null : (_) => _interpret(),
                        onChanged: (_) => setState(() {
                          _intent = null;
                          _wallet = null;
                          _accountTotals = null;
                          _aiSuggested = false;
                        }),
                      ),
                      Row(children: [
                        Expanded(
                            child: FilledButton(
                          onPressed: busy ? null : _interpret,
                          child: Text(_label('Continue', 'متابعة')),
                        )),
                        FutureBuilder<bool>(
                          future: _voiceAvailable,
                          builder: (context, snapshot) => snapshot.data == true
                              ? IconButton(
                                  onPressed: _requestingAi ? null : _dictate,
                                  icon: Icon(
                                      _listening ? Icons.stop : Icons.mic_none),
                                  tooltip: _listening
                                      ? _label(
                                          'Cancel dictation', 'إلغاء الإملاء')
                                      : _label('Dictate offline',
                                          'الإملاء دون اتصال'),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ]),
                    ]),
              ),
              const SizedBox(height: 12),
              CashuOptionSection(
                icon: Icons.cloud_outlined,
                title: _label(
                    'Online assistant options', 'خيارات المساعد أونلاين'),
                children: [
                  CashuActionRow(
                      icon: Icons.auto_awesome_outlined,
                      title: _label('Use OpenAI', 'استخدام OpenAI'),
                      onTap: busy ? null : _interpretOnline),
                  CashuActionRow(
                      icon: Icons.key_outlined,
                      title: _label('AI settings', 'إعدادات الذكاء الاصطناعي'),
                      onTap: _requestingAi ? null : _editAiSettings),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _draft(FinancialAssistantIntent intent) {
    final income = intent.type == FinancialAssistantIntentType.addIncome;
    final transfer = intent.type == FinancialAssistantIntentType.transfer;
    final amount = intent.amount;
    if ((!income &&
            !transfer &&
            intent.type != FinancialAssistantIntentType.addExpense) ||
        amount == null ||
        !amount.isFinite ||
        amount <= 0 ||
        amount > 999999999999 ||
        intent.currency == null) {
      return Text(
        _label(
          'Enter an income, expense, or transfer with an amount and currency.',
          'أدخل دخلاً أو مصروفًا أو تحويلاً مع المبلغ والعملة.',
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
              '${transfer ? '' : income ? '+' : '−'}$amount ${intent.currency!.toUpperCase()}',
            ),
            DropdownButton<TransactionWallet>(
              isExpanded: true,
              hint: Text(transfer
                  ? _label('Source account', 'الحساب المصدر')
                  : _label('Account', 'الحساب')),
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
                  : () {
                      final wallet = _wallet!;
                      if (transfer) {
                        openBalanceTransfer(
                            context,
                            TransferBalancePage(
                              wallet: wallet,
                              allowEditWallet: false,
                              initialAmount: amount,
                              initialAmountWallet: wallet,
                            ));
                        return;
                      }
                      Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => AddTransactionPage(
                          selectedIncome: income,
                          selectedAmount: income ? amount : -amount,
                          selectedTitle: intent.merchantOrTitle,
                          selectedWallet: wallet,
                          startInitialAddTransactionSequence: false,
                          routesToPopAfterDelete: RoutesToPopAfterDelete.None,
                        ),
                      ));
                    },
              child: Text(transfer
                  ? _label('Review transfer', 'مراجعة التحويل')
                  : _label('Review transaction', 'مراجعة المعاملة')),
            ),
          ],
        );
      },
    );
  }
}
