import 'package:budget/widgets/cashuPickers.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/financialMessageParser.dart';
import 'package:flutter/material.dart';
import 'package:budget/widgets/cashuSurfaces.dart';
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
  const BankCertificatesPage({super.key, this.openForm = false});

  final bool openForm;

  @override
  State<BankCertificatesPage> createState() => _BankCertificatesPageState();
}

class _BankCertificatesPageState extends State<BankCertificatesPage> {
  late var _certificates = database.getBankCertificates();

  void _reload() =>
      setState(() => _certificates = database.getBankCertificates());

  @override
  void initState() {
    super.initState();
    if (widget.openForm) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _add();
      });
    }
  }

  Future<void> _add() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const _CertificateForm()),
    );
    if (mounted && saved == true) _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: CashuColors(context).canvas,
        appBar: AppBar(
            backgroundColor: CashuColors(context).canvas,
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
                    CashuGreenPanel(
                        child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.workspace_premium_outlined,
                            color: Color(0xffb4edb8), size: 32),
                        const SizedBox(height: 10),
                        Text(
                            _label(context, 'Certificate portfolio',
                                'شهاداتك البنكية'),
                            style: const TextStyle(
                                color: Color(0xfff3faf4),
                                fontSize: 24,
                                fontWeight: FontWeight.w800)),
                        if (rows.isNotEmpty)
                          Text(
                              _label(
                                  context,
                                  '${rows.length} recorded certificates',
                                  '${rows.length} شهادة مسجّلة'),
                              style: const TextStyle(color: Color(0xffc4dace))),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xffb4edb8),
                            foregroundColor: const Color(0xff183127),
                          ),
                          onPressed: _add,
                          icon: const Icon(Icons.add),
                          label: Text(_label(
                              context, 'Add a certificate', 'إضافة شهادة')),
                        ),
                      ],
                    )),
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
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: CashuPanel(
                            padding: EdgeInsets.zero,
                            child: ListTile(
                              leading: const CashuIconTile(
                                  Icons.lock_clock_outlined),
                              title: Text(item.name),
                              subtitle: Text([
                                if (item.bank.isNotEmpty) item.bank,
                                _date(context, item.maturityDay),
                              ].join(' · ')),
                              trailing: Text(
                                  _amount(context, item.principalMinor),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                              onTap: () async {
                                await Navigator.of(context)
                                    .push<void>(MaterialPageRoute(
                                  builder: (_) =>
                                      _CertificateDetails(id: item.id),
                                ));
                                if (mounted) _reload();
                              },
                            )),
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
  String? _bank;
  final _principal = TextEditingController();
  final _returnAmount = TextEditingController();
  final _rate = TextEditingController();
  bool _estimateFromRate = false;
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
    for (final controller in [_name, _principal, _returnAmount, _rate]) {
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

  int? get _payoutMinor {
    if (!_estimateFromRate || _months == 0) return _minor(_returnAmount.text);
    final principal = _minor(_principal.text);
    final basisPoints = _minor(_rate.text);
    if (principal == null || basisPoints == null || basisPoints > 10000)
      return null;
    return estimateCertificatePayoutMinor(principal, basisPoints, _months);
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    final payout = _payoutMinor;
    if (payout == null || payout < 1) {
      setState(() => _error = _label(
            context,
            'Enter a payout of at least one piastre.',
            'أدخل عائد لا يقل عن قرش واحد.',
          ));
      return;
    }
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
        bank: _bank ?? '',
        walletPk: _account!,
        currency: 'egp',
        principalMinor: _minor(_principal.text)!,
        payoutMinor: payout,
        firstPayoutDay: certificateDay(first),
        maturityDay: certificateDay(maturity),
        intervalMonths: _months,
        autoFromDay: _automatic ? today : null,
      ));
      if (_automatic && mounted) await postDueBankCertificatePayouts(context);
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
    final colors = CashuColors(context);
    String label(String en, String ar) => _label(context, en, ar);
    final estimate = _payoutMinor;
    final useRate = _estimateFromRate && _months != 0;
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(13),
      borderSide: BorderSide(color: colors.border),
    );
    InputDecoration decoration(String title, {String? suffix}) =>
        InputDecoration(
          labelText: title,
          filled: true,
          fillColor: colors.canvas,
          suffixText: suffix,
          border: inputBorder,
          enabledBorder: inputBorder,
        );
    String? validateAmount(String? value) => _minor(value ?? '') == null
        ? label('Enter a positive amount with up to two decimals',
            'أدخل مبلغًا موجبًا حتى منزلتين عشريتين')
        : null;
    Widget input(TextEditingController controller, String title,
            {bool amount = false, bool rate = false}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextFormField(
            controller: controller,
            enabled: !_saving,
            maxLength: amount || rate
                ? null
                : controller == _name
                    ? NAME_LIMIT - 32
                    : NAME_LIMIT,
            keyboardType: amount || rate
                ? const TextInputType.numberWithOptions(decimal: true)
                : null,
            decoration: decoration(title,
                suffix: rate
                    ? '%'
                    : amount
                        ? 'EGP'
                        : null),
            onChanged: amount || rate ? (_) => setState(() {}) : null,
            validator: rate
                ? (value) {
                    final percent = _minor(value ?? '');
                    return percent != null && percent <= 10000
                        ? null
                        : label('Enter a rate above 0% and up to 100%',
                            'أدخل نسبة أكبر من صفر وحتى ١٠٠٪');
                  }
                : amount
                    ? validateAmount
                    : controller == _name
                        ? (value) => value?.trim().isNotEmpty == true
                            ? null
                            : label('Enter a name', 'اكتب اسم الشهادة')
                        : null,
          ),
        );

    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
          backgroundColor: colors.canvas,
          title: Text(label('Add a certificate', 'إضافة شهادة'))),
      body: SafeArea(
          child: Center(
              child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
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
            if (accounts.isEmpty)
              return Center(
                  child: Text(label(
                'Add an active EGP account first.',
                'أضف حسابًا نشطًا بالجنيه الأول.',
              )));
            return Column(children: [
              Expanded(
                  child: Form(
                key: _form,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        CashuGreenPanel(
                            child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.workspace_premium_outlined,
                                color: Color(0xffb4edb8)),
                            const SizedBox(height: 8),
                            Text(
                                label('Return per payout', 'العائد في كل دفعة'),
                                style:
                                    const TextStyle(color: Color(0xffc4dace))),
                            Text(
                                estimate == null
                                    ? '—'
                                    : _amount(context, estimate),
                                style: const TextStyle(
                                  color: Color(0xfff1faf3),
                                  fontSize: 30,
                                  fontWeight: FontWeight.w800,
                                )),
                          ],
                        )),
                        CashuSectionTitle(
                            label('Certificate terms', 'بيانات الشهادة')),
                        CashuPanel(
                            child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            input(_name,
                                label('Certificate name', 'اسم الشهادة')),
                            CashuActionRow(
                              icon: Icons.account_balance_outlined,
                              title:
                                  label('Bank or provider', 'البنك أو التطبيق'),
                              detail: _bank ?? label('Optional', 'اختياري'),
                              onTap: _saving
                                  ? null
                                  : () async {
                                      final result = await pickCashuInstitution(
                                          context, _bank,
                                          mobileWallet: false);
                                      if (result != null && mounted) {
                                        setState(() => _bank =
                                            result.isEmpty ? null : result);
                                      }
                                    },
                            ),
                            input(
                                _principal, label('Principal', 'قيمة الشهادة'),
                                amount: true),
                            Text(label('Payout frequency', 'دورية الصرف'),
                                style: TextStyle(
                                    color: colors.ink,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 5),
                            Wrap(spacing: 7, runSpacing: 5, children: [
                              for (final (months, title) in [
                                (1, label('Monthly', 'شهري')),
                                (3, label('Quarterly', 'ربع سنوي')),
                                (6, label('Semiannual', 'نصف سنوي')),
                                (12, label('Yearly', 'سنوي')),
                                (0, label('At maturity', 'عند الاستحقاق')),
                              ])
                                ChoiceChip(
                                  label: Text(title),
                                  selected: _months == months,
                                  onSelected: _saving
                                      ? null
                                      : (_) => setState(() => _months = months),
                                ),
                            ]),
                            if (_months != 0)
                              SwitchListTile(
                                title: Text(label('Calculate from annual rate',
                                    'احسبه من العائد السنوي')),
                                contentPadding: EdgeInsets.zero,
                                value: _estimateFromRate,
                                onChanged: _saving
                                    ? null
                                    : (value) => setState(
                                        () => _estimateFromRate = value),
                              ),
                            const SizedBox(height: 8),
                            if (useRate) ...[
                              input(_rate,
                                  label('Annual rate', 'نسبة العائد السنوي'),
                                  rate: true),
                              Text(
                                  label(
                                      'Fixed-rate estimate. Enter the exact payout if your bank uses a different schedule or calculation.',
                                      'ده تقدير لعائد ثابت. أدخل مبلغ الدفعة الفعلي لو البنك بيحسب العائد بطريقة مختلفة.'),
                                  style: TextStyle(color: colors.muted)),
                            ] else
                              input(
                                  _returnAmount,
                                  label('Amount per payout (EGP)',
                                      'قيمة العائد في كل دفعة (جنيه)'),
                                  amount: true),
                          ],
                        )),
                        CashuSectionTitle(label('Schedule and destination',
                            'المواعيد وحساب العائد')),
                        CashuPanel(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                DropdownButtonFormField<String>(
                                  initialValue: _account,
                                  isExpanded: true,
                                  decoration: decoration(label(
                                      'Deposit the return into',
                                      'العائد ينزل على حساب')),
                                  items: [
                                    for (final account in accounts)
                                      DropdownMenuItem(
                                          value: account.id,
                                          child: Text(account.name,
                                              overflow: TextOverflow.ellipsis)),
                                  ],
                                  onChanged: _saving
                                      ? null
                                      : (value) =>
                                          setState(() => _account = value),
                                ),
                                if (_months != 0)
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(
                                        Icons.event_available_outlined),
                                    title: Text(label(
                                        'First payout', 'تاريخ أول عائد')),
                                    subtitle: _first == null
                                        ? null
                                        : Text(_date(
                                            context, certificateDay(_first!))),
                                    onTap: _saving
                                        ? null
                                        : () => _pickDate(maturity: false),
                                  ),
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(Icons.event_outlined),
                                  title: Text(label('Maturity date',
                                      'تاريخ استحقاق الشهادة')),
                                  subtitle: _maturity == null
                                      ? null
                                      : Text(_date(
                                          context, certificateDay(_maturity!))),
                                  onTap: _saving
                                      ? null
                                      : () => _pickDate(maturity: true),
                                ),
                              ]),
                        ),
                        CashuSectionTitle(
                            label('Record the return', 'طريقة تسجيل العائد')),
                        for (final (automatic, icon, title, detail) in [
                          (
                            false,
                            Icons.touch_app_outlined,
                            label(
                                'Confirm when received', 'أكّد الاستلام بنفسك'),
                            label('Record income when it reaches your account.',
                                'سجّل العائد لما ينزل في الحساب.')
                          ),
                          (
                            true,
                            Icons.event_repeat_outlined,
                            label('Record on schedule', 'سجّل حسب المواعيد'),
                            label('CashU adds due payouts to the selected account when it opens or resumes. Review each payout to confirm the bank actually paid it.',
                                'CashU بيسجّل الدفعات المستحقة كدخل في الحساب اللي اخترته عند الفتح أو الرجوع للتطبيق. راجع البنك عشان تتأكد إن العائد نزل فعلًا.')
                          ),
                        ])
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: CashuPanel(
                              highlighted: _automatic == automatic,
                              onTap: _saving
                                  ? null
                                  : () =>
                                      setState(() => _automatic = automatic),
                              child: Row(children: [
                                CashuIconTile(icon, size: 36),
                                const SizedBox(width: 10),
                                Expanded(
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                      Text(title,
                                          style: TextStyle(
                                              color: colors.ink,
                                              fontWeight: FontWeight.w700)),
                                      Text(detail,
                                          style:
                                              TextStyle(color: colors.muted)),
                                    ])),
                                Icon(
                                    _automatic == automatic
                                        ? Icons.check_circle
                                        : Icons.circle_outlined,
                                    size: 20,
                                    color: colors.accent),
                              ]),
                            ),
                          ),
                      ]),
                ),
              )),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(_error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      ),
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      child: Text(label('Save certificate', 'حفظ الشهادة')),
                    ),
                  ],
                ),
              ),
            ]);
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
