import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/financialMessageParser.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show NumberFormat;

typedef _PayoutAccount = ({String id, String name, String currency});

String _label(BuildContext context, String en, String ar) =>
    Localizations.localeOf(context).languageCode == 'ar' ? ar : en;

String _amount(BuildContext context, int minor) =>
    '${NumberFormat.decimalPattern(Localizations.localeOf(context).toString()).format(minor / 100)} EGP';

String _date(BuildContext context, int day) =>
    MaterialLocalizations.of(context).formatMediumDate(certificateDate(day));

Future<List<_PayoutAccount>> _loadAccounts() async =>
    (await database.getFinancialInsightsAccounts())
        .where((account) => account.currency.toLowerCase() == 'egp')
        .toList();

class BankCertificatesPage extends StatefulWidget {
  const BankCertificatesPage({super.key});

  @override
  State<BankCertificatesPage> createState() => _BankCertificatesPageState();
}

class _BankCertificatesPageState extends State<BankCertificatesPage> {
  late var _certificates = database.getBankCertificates();

  void _reload() =>
      setState(() => _certificates = database.getBankCertificates());

  Future<void> _add() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const _CertificateForm()),
    );
    if (mounted && saved == true) _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title:
                Text(_label(context, 'Bank certificates', 'الشهادات البنكية'))),
        body: SafeArea(
          child: FutureBuilder<List<BankCertificate>>(
            future: _certificates,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                    child: TextButton(
                  onPressed: _reload,
                  child: Text(_label(context, 'Retry loading certificates',
                      'أعد تحميل الشهادات')),
                ));
              }
              if (!snapshot.hasData)
                return const Center(child: CircularProgressIndicator());
              final rows = snapshot.data!;
              return Center(
                  child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    FilledButton.icon(
                      onPressed: _add,
                      icon: const Icon(Icons.add),
                      label: Text(
                          _label(context, 'Add a certificate', 'إضافة شهادة')),
                    ),
                    const SizedBox(height: 16),
                    if (rows.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Text(
                          _label(context, 'No certificates yet',
                              'لسه مفيش شهادات مسجّلة'),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    for (final item in rows)
                      Card(
                        elevation: 0,
                        color:
                            Theme.of(context).colorScheme.surfaceContainerLow,
                        child: ListTile(
                          leading: const CircleAvatar(
                              child: Icon(Icons.savings_outlined)),
                          title: Text(item.name),
                          subtitle: Text([
                            if (item.bank.isNotEmpty) item.bank,
                            _amount(context, item.principalMinor),
                            _date(context, item.maturityDay),
                          ].join(' · ')),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            await Navigator.of(context)
                                .push<void>(MaterialPageRoute(
                              builder: (_) => _CertificateDetails(id: item.id),
                            ));
                            if (mounted) _reload();
                          },
                        ),
                      ),
                  ],
                ),
              ));
            },
          ),
        ),
      );
}

class _CertificateForm extends StatefulWidget {
  const _CertificateForm();

  @override
  State<_CertificateForm> createState() => _CertificateFormState();
}

class _CertificateFormState extends State<_CertificateForm> {
  final _name = TextEditingController();
  final _bank = TextEditingController();
  final _principal = TextEditingController();
  final _returnAmount = TextEditingController();
  final _id = uuid.v4();
  final _form = GlobalKey<FormState>();
  late var _accounts = _loadAccounts();
  String? _account;
  int _months = 1;
  DateTime? _first;
  DateTime? _maturity;
  bool _automatic = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final controller in [_name, _bank, _principal, _returnAmount]) {
      controller.dispose();
    }
    super.dispose();
  }

  int? _minor(String value) {
    final normalized = FinancialMessageParser.normalize(value.trim());
    if (!RegExp(r'^\d{1,12}(?:\.\d{1,2})?$').hasMatch(normalized)) return null;
    final pieces = normalized.split('.');
    final minor = int.parse(pieces.first) * 100 +
        (pieces.length == 1 ? 0 : int.parse(pieces.last.padRight(2, '0')));
    return minor > 0 && minor <= 99999999999900 ? minor : null;
  }

  Future<void> _pickDate({required bool maturity}) async {
    final today = DateTime.now();
    final value = await showDatePicker(
      context: context,
      initialDate: (maturity ? _maturity : _first) ?? today,
      firstDate: DateTime(1980),
      lastDate: DateTime(today.year + 50, 12, 31),
    );
    if (mounted && value != null) {
      setState(() {
        if (maturity) {
          _maturity = value;
        } else {
          _first = value;
        }
        _error = null;
      });
    }
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    final maturity = _maturity;
    final first = _months == 0 ? maturity : _first;
    if (_account == null ||
        first == null ||
        maturity == null ||
        first.isAfter(maturity)) {
      setState(() => _error = _label(
            context,
            'Select an account and valid payout and maturity dates.',
            'اختار حساب العائد ومواعيد صرف واستحقاق صحيحة.',
          ));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final today = certificateDay(DateTime.now());
      await database.createBankCertificate(BankCertificate(
        id: _id,
        name: _name.text.trim(),
        bank: _bank.text.trim(),
        walletPk: _account!,
        currency: 'egp',
        principalMinor: _minor(_principal.text)!,
        payoutMinor: _minor(_returnAmount.text)!,
        firstPayoutDay: certificateDay(first),
        maturityDay: certificateDay(maturity),
        intervalMonths: _months,
        autoFromDay: _automatic ? today : null,
      ));
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted)
        setState(() => _error = _label(
              context,
              'Could not save the certificate. Check its dates and payout account.',
              'تعذّر حفظ الشهادة. راجع التواريخ وحساب العائد.',
            ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    String label(String en, String ar) => _label(context, en, ar);
    String? validateAmount(String? value) => _minor(value ?? '') == null
        ? label('Enter an amount in EGP with up to two decimals',
            'اكتب مبلغًا بالجنيه حتى منزلتين عشريتين')
        : null;
    Widget input(TextEditingController controller, String title,
            {bool amount = false}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextFormField(
            controller: controller,
            enabled: !_saving,
            maxLength: amount
                ? null
                : controller == _name
                    ? NAME_LIMIT - 32
                    : NAME_LIMIT,
            keyboardType: amount
                ? const TextInputType.numberWithOptions(decimal: true)
                : null,
            decoration: InputDecoration(
                labelText: title, border: const OutlineInputBorder()),
            validator: amount
                ? validateAmount
                : controller == _name
                    ? (value) => value?.trim().isNotEmpty == true
                        ? null
                        : label('Enter a name', 'اكتب اسم الشهادة')
                    : null,
          ),
        );
    return Scaffold(
      appBar: AppBar(title: Text(label('Add a certificate', 'إضافة شهادة'))),
      body: SafeArea(
          child: Center(
              child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: FutureBuilder<List<_PayoutAccount>>(
          future: _accounts,
          builder: (context, snapshot) {
            if (snapshot.hasError)
              return Center(
                  child: TextButton(
                onPressed: () => setState(() => _accounts = _loadAccounts()),
                child:
                    Text(label('Retry loading accounts', 'أعد تحميل الحسابات')),
              ));
            if (!snapshot.hasData)
              return const Center(child: CircularProgressIndicator());
            final accounts = snapshot.data!;
            if (accounts.isEmpty) {
              return Center(
                  child: Text(label('Add an active EGP account first.',
                      'أضف حسابًا نشطًا بالجنيه الأول.')));
            }
            return Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  input(_name, label('Certificate name', 'اسم الشهادة')),
                  input(_bank,
                      label('Bank name (optional)', 'اسم البنك (اختياري)')),
                  input(
                      _principal,
                      label(
                          'Certificate principal (EGP)', 'قيمة الشهادة (جنيه)'),
                      amount: true),
                  input(
                      _returnAmount,
                      label('Amount per payout (EGP)',
                          'قيمة العائد في كل دفعة (جنيه)'),
                      amount: true),
                  DropdownButtonFormField<String>(
                    initialValue: _account,
                    isExpanded: true,
                    decoration: InputDecoration(
                        labelText: label(
                            'Deposit the return into', 'العائد ينزل على حساب')),
                    items: [
                      for (final account in accounts)
                        DropdownMenuItem(
                            value: account.id,
                            child: Text(account.name,
                                overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _account = value),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: _months,
                    decoration: InputDecoration(
                        labelText: label('Payout schedule', 'دورية الصرف')),
                    items: [
                      DropdownMenuItem(
                          value: 1, child: Text(label('Monthly', 'شهري'))),
                      DropdownMenuItem(
                          value: 3,
                          child: Text(label('Quarterly', 'ربع سنوي'))),
                      DropdownMenuItem(
                          value: 6,
                          child: Text(label('Semiannual', 'نصف سنوي'))),
                      DropdownMenuItem(
                          value: 12, child: Text(label('Yearly', 'سنوي'))),
                      DropdownMenuItem(
                          value: 0,
                          child: Text(label('At maturity', 'عند الاستحقاق'))),
                    ],
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _months = value!),
                  ),
                  if (_months != 0)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.event_available_outlined),
                      title: Text(label('First payout', 'تاريخ أول عائد')),
                      subtitle: _first == null
                          ? null
                          : Text(_date(context, certificateDay(_first!))),
                      onTap: _saving ? null : () => _pickDate(maturity: false),
                    ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.event_outlined),
                    title:
                        Text(label('Maturity date', 'تاريخ استحقاق الشهادة')),
                    subtitle: _maturity == null
                        ? null
                        : Text(_date(context, certificateDay(_maturity!))),
                    onTap: _saving ? null : () => _pickDate(maturity: true),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(label('Automatically log future payouts',
                        'سجّل العوائد القادمة تلقائيًا')),
                    subtitle: Text(label(
                      'CashU logs scheduled amounts when you open the app. Leave off to confirm each deposit.',
                      'CashU بيسجّل المبلغ حسب الجدول وقت فتح التطبيق. اقفل الاختيار لو عايز تأكد كل دفعة بنفسك.',
                    )),
                    value: _automatic,
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _automatic = value),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(_error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    ),
                  const SizedBox(height: 12),
                  FilledButton(
                      onPressed: _saving ? null : _save,
                      child: Text(label('Save certificate', 'حفظ الشهادة'))),
                ],
              ),
            );
          },
        ),
      ))),
    );
  }
}

class _CertificateDetails extends StatefulWidget {
  const _CertificateDetails({required this.id});
  final String id;

  @override
  State<_CertificateDetails> createState() => _CertificateDetailsState();
}

class _CertificateDetailsState extends State<_CertificateDetails> {
  late var _data = _load();
  bool _busy = false;
  String? _error;

  Future<(BankCertificate, Set<int>, List<_PayoutAccount>)> _load() async => (
        await database.getBankCertificate(widget.id),
        await database.recordedCertificateDays(widget.id),
        await _loadAccounts()
      );

  void _reload() => setState(() => _data = _load());

  Future<void> _record(BankCertificate certificate, int day, String account) =>
      _change(() async {
        final candidates =
            await database.certificatePayoutCandidates(certificate, day);
        if (!mounted) return;
        final choice = await showDialog<(Transaction?, bool)>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(candidates.isEmpty
                ? _label(
                    context, 'Confirm payout received', 'أكد إن العائد نزل')
                : _label(context, 'Similar income already recorded',
                    'فيه دخل مشابه متسجّل')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                      '${_amount(context, certificate.payoutMinor)} · $account · ${_date(context, day)}'),
                  for (final entry in candidates)
                    ListTile(
                      title: Text(entry.name.isEmpty
                          ? _label(context, 'Income', 'دخل')
                          : entry.name),
                      subtitle: Text(_label(context, 'Use this transaction',
                          'اربط بالمعاملة دي')),
                      leading: const Icon(Icons.link),
                      onTap: () => Navigator.pop(context, (entry, false)),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(_label(context, 'Cancel', 'إلغاء')),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(context, (null, candidates.isNotEmpty)),
                child: Text(candidates.isEmpty
                    ? _label(context, 'Record income', 'تسجيل دخل')
                    : _label(
                        context, 'Record separate income', 'سجّل دخل منفصل')),
              ),
            ],
          ),
        );
        if (!mounted || choice == null) return;
        await database.recordCertificatePayout(
          widget.id,
          day,
          now: DateTime.now(),
          existing: choice.$1,
          confirmedSeparate: choice.$2,
          arabic: Localizations.localeOf(context).languageCode == 'ar',
        );
      });

  Future<void> _change(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) _reload();
    } catch (_) {
      if (mounted)
        setState(() => _error = _label(
              context,
              'Could not save. Check the payout account and try again.',
              'تعذّر الحفظ. راجع حساب العائد وحاول تاني.',
            ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    String label(String en, String ar) => _label(context, en, ar);
    return Scaffold(
      appBar:
          AppBar(title: Text(label('Certificate payouts', 'عوائد الشهادة'))),
      body: SafeArea(
          child: FutureBuilder(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.hasError)
            return Center(
                child: TextButton(
              onPressed: _reload,
              child:
                  Text(label('Retry loading certificate', 'أعد تحميل الشهادة')),
            ));
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          final (certificate, recorded, accounts) = snapshot.data!;
          final today = certificateDay(DateTime.now());
          final account =
              accounts.where((a) => a.id == certificate.walletPk).firstOrNull;
          final days = certificate.payoutDays().toList();
          return Center(
              child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView.builder(
              padding: const EdgeInsets.all(20),
              itemCount: days.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(certificate.name,
                              style: Theme.of(context).textTheme.headlineSmall),
                          Text(_amount(context, certificate.principalMinor)),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            key: ValueKey(account?.id),
                            initialValue: account?.id,
                            isExpanded: true,
                            decoration: InputDecoration(
                                labelText:
                                    label('Payout account', 'حساب العائد')),
                            items: [
                              for (final entry in accounts)
                                DropdownMenuItem(
                                    value: entry.id,
                                    child: Text(entry.name,
                                        overflow: TextOverflow.ellipsis)),
                            ],
                            onChanged: _busy
                                ? null
                                : (id) {
                                    if (id != null)
                                      _change(() =>
                                          database.configureCertificatePayout(
                                            widget.id,
                                            id,
                                            automatic:
                                                certificate.autoFromDay != null,
                                            now: DateTime.now(),
                                          ));
                                  },
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(label(
                                'Automatically log future payouts',
                                'سجّل العوائد القادمة تلقائيًا')),
                            value: certificate.autoFromDay != null,
                            onChanged: _busy || account == null
                                ? null
                                : (value) => _change(
                                      () => database.configureCertificatePayout(
                                          widget.id, account.id,
                                          automatic: value,
                                          now: DateTime.now()),
                                    ),
                          ),
                          if (_error != null)
                            Text(_error!,
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error)),
                        ]),
                  );
                }
                final day = days[index - 1];
                final posted = recorded.contains(day);
                final canRecord =
                    !posted && day <= today && !_busy && account != null;
                return Card(
                  elevation: 0,
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  child: ListTile(
                    leading: Icon(posted
                        ? Icons.check_circle_outline
                        : Icons.calendar_today_outlined),
                    title: Text(_date(context, day)),
                    subtitle: Text(_amount(context, certificate.payoutMinor)),
                    trailing: posted
                        ? Text(label('Recorded', 'اتسجّل'))
                        : day > today
                            ? Text(label('Upcoming', 'قادم'))
                            : TextButton(
                                onPressed: canRecord
                                    ? () =>
                                        _record(certificate, day, account.name)
                                    : null,
                                child: Text(label('Record', 'سجّل')),
                              ),
                  ),
                );
              },
            ),
          ));
        },
      )),
    );
  }
}
