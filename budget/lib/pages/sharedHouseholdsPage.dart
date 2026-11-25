import 'dart:async';

import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/householdFirebase.dart';
import 'package:budget/struct/sharedHousehold.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

String _text(BuildContext context, String english, String arabic) =>
    Localizations.localeOf(context).languageCode == 'ar' ? arabic : english;

void _notice(BuildContext context, String en, String ar) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(_text(context, en, ar))),
  );
}

Future<T?> _open<T>(BuildContext context, Widget page) =>
    Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => page));

Future<String?> _prompt(
  BuildContext context,
  String label, {
  int limit = 100,
  bool latin = false,
  String? Function(String)? validate,
}) async {
  final form = GlobalKey<FormState>();
  var value = '';
  return showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(label),
      content: Form(
        key: form,
        child: TextFormField(
          maxLength: limit,
          autofocus: true,
          textDirection: latin ? TextDirection.ltr : null,
          onChanged: (text) => value = text.trim(),
          validator: (_) => value.isEmpty
              ? _text(context, 'Enter a value.', 'أدخل قيمة.')
              : validate?.call(value),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(_text(context, 'Cancel', 'إلغاء'))),
        FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(dialog, value);
            },
            child: Text(_text(context, 'Continue', 'متابعة'))),
      ],
    ),
  );
}

Future<bool> _confirm(BuildContext context, String title,
        {String? description}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: description == null ? null : Text(description),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: Text(_text(context, 'Cancel', 'إلغاء'))),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(_text(context, 'Confirm', 'تأكيد'))),
        ],
      ),
    ) ??
    false;

String? _checkEmail(BuildContext context, String value) =>
    RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value)
        ? null
        : _text(
            context, 'Enter a valid email.', 'أدخل بريدًا إلكترونيًا صالحًا.');

Widget _load<T>(Future<T> future, Widget Function(BuildContext, T) ready) =>
    FutureBuilder<T>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done &&
            !snapshot.hasData) {
          return const LinearProgressIndicator();
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return ListTile(
              title: Text(_text(
            context,
            'Could not load shared data. Refresh to check access.',
            'تعذّر تحميل البيانات المشتركة. حدّث الصفحة للتحقق من الصلاحية.',
          )));
        }
        return ready(context, snapshot.data as T);
      },
    );

Widget _offline(BuildContext context) => ListTile(
      leading: const Icon(Icons.cloud_off_outlined),
      title: Text(_text(context, 'Offline · last saved data',
          'دون اتصال · آخر بيانات محفوظة')),
    );

class SharedHouseholdsPage extends StatefulWidget {
  const SharedHouseholdsPage({super.key});

  @override
  State<SharedHouseholdsPage> createState() => _SharedHouseholdsPageState();
}

class _SharedHouseholdsPageState extends State<SharedHouseholdsPage> {
  late var _service = HouseholdFirebase.open();
  String _title(BuildContext context) =>
      _text(context, 'Household sharing', 'المشاركة الأسرية');

  @override
  Widget build(BuildContext context) {
    if (!householdFirebaseConfigured) {
      return PageFramework(
          title: _title(context),
          capitalizeTitle: false,
          listWidgets: [
            ListTile(
                title: Text(_text(
              context,
              'Household sharing needs a service configured for this build.',
              'المشاركة الأسرية تحتاج إعداد الخدمة لهذه النسخة.',
            ))),
          ]);
    }
    return FutureBuilder<HouseholdFirebase>(
      future: _service,
      builder: (context, snapshot) {
        final service = snapshot.data;
        if (service != null) return _HouseholdAuthentication(service: service);
        return PageFramework(
            title: _title(context),
            capitalizeTitle: false,
            listWidgets: [
              if (snapshot.hasError)
                ListTile(
                  title: Text(_text(
                      context,
                      'Could not open household sharing.',
                      'تعذّر فتح المشاركة الأسرية.')),
                  trailing: IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: _text(context, 'Retry', 'حاول مجددًا'),
                      onPressed: () =>
                          setState(() => _service = HouseholdFirebase.open())),
                )
              else
                const LinearProgressIndicator(),
            ]);
      },
    );
  }
}

class _HouseholdAuthentication extends StatefulWidget {
  const _HouseholdAuthentication({required this.service});
  final HouseholdFirebase service;

  @override
  State<_HouseholdAuthentication> createState() =>
      _HouseholdAuthenticationState();
}

class _HouseholdAuthenticationState extends State<_HouseholdAuthentication> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  late final _users = widget.service.auth.userChanges();
  late final _initialUser = widget.service.auth.currentUser;
  bool _busy = false;

  Future<void> _auth(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      if (error.code == 'weak-password') {
        _notice(context, 'Choose a stronger password.', 'اختر كلمة مرور أقوى.');
      } else if (error.code == 'network-request-failed') {
        _notice(context, 'Connect to the internet and try again.',
            'اتصل بالإنترنت وحاول مرة أخرى.');
      } else {
        _notice(context, 'Could not complete the sign-in action.',
            'تعذّر إكمال عملية تسجيل الدخول.');
      }
    } catch (_) {
      if (mounted)
        _notice(context, 'Could not complete the sign-in action.',
            'تعذّر إكمال عملية تسجيل الدخول.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _submit({required bool create}) {
    if (!_form.currentState!.validate()) return;
    unawaited(_auth(() async {
      final email = _email.text.trim();
      final password = _password.text;
      _password.clear();
      if (create) {
        final result = await widget.service.auth
            .createUserWithEmailAndPassword(email: email, password: password);
        await result.user!.sendEmailVerification();
        if (mounted)
          _notice(context, 'Verification email sent.', 'تم إرسال بريد التحقق.');
      } else {
        await widget.service.auth
            .signInWithEmailAndPassword(email: email, password: password);
      }
    }));
  }

  Future<void> _resetPassword() async {
    final email = await _prompt(context,
        _text(context, 'Password reset email', 'بريد إعادة تعيين كلمة المرور'),
        limit: 254,
        latin: true,
        validate: (value) => _checkEmail(context, value));
    if (email == null || !mounted) return;
    await _auth(() async {
      await widget.service.auth.sendPasswordResetEmail(email: email);
      if (mounted)
        _notice(context, 'Check your email for the reset link.',
            'راجع بريدك للحصول على رابط إعادة التعيين.');
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<User?>(
        stream: _users,
        initialData: _initialUser,
        builder: (context, snapshot) {
          final user = snapshot.data;
          if (user != null && user.emailVerified) {
            return _HouseholdDirectory(
              key: ValueKey(user.uid),
              service: widget.service,
              user: user,
            );
          }
          return PageFramework(
            title: _text(context, 'Household sharing', 'المشاركة الأسرية'),
            capitalizeTitle: false,
            listWidgets: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: user == null
                    ? Form(
                        key: _form,
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TextFormField(
                                controller: _email,
                                enabled: !_busy,
                                maxLength: 254,
                                keyboardType: TextInputType.emailAddress,
                                textDirection: TextDirection.ltr,
                                decoration: InputDecoration(
                                    labelText: _text(
                                        context, 'Email', 'البريد الإلكتروني')),
                                validator: (value) =>
                                    _checkEmail(context, value?.trim() ?? ''),
                              ),
                              TextFormField(
                                controller: _password,
                                enabled: !_busy,
                                obscureText: true,
                                enableSuggestions: false,
                                autocorrect: false,
                                decoration: InputDecoration(
                                    labelText: _text(
                                        context, 'Password', 'كلمة المرور')),
                                validator: (value) =>
                                    value == null || value.isEmpty
                                        ? _text(context, 'Enter a password.',
                                            'أدخل كلمة المرور.')
                                        : null,
                              ),
                              FilledButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _submit(create: false),
                                  child: Text(_text(
                                      context, 'Sign in', 'تسجيل الدخول'))),
                              OutlinedButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _submit(create: true),
                                  child: Text(_text(
                                      context,
                                      'Create household login',
                                      'إنشاء حساب للمشاركة الأسرية'))),
                              TextButton(
                                  onPressed: _busy ? null : _resetPassword,
                                  child: Text(_text(context, 'Reset password',
                                      'إعادة تعيين كلمة المرور'))),
                            ]),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                            Text(_text(
                                context,
                                'Verify this email to join or create a household.',
                                'أكّد هذا البريد للانضمام إلى أسرة أو إنشائها.')),
                            Text(user.email ?? ''),
                            FilledButton(
                              onPressed: _busy
                                  ? null
                                  : () => _auth(() async {
                                        await user.reload();
                                        final refreshed =
                                            widget.service.auth.currentUser;
                                        if (refreshed?.emailVerified == true) {
                                          await refreshed!.getIdToken(true);
                                        } else if (mounted) {
                                          _notice(
                                              context,
                                              'Email verification is still pending.',
                                              'التحقق من البريد ما زال معلقًا.');
                                        }
                                      }),
                              child: Text(_text(context, 'Check verification',
                                  'التحقق من التأكيد')),
                            ),
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _auth(() async {
                                        await user.sendEmailVerification();
                                        if (mounted)
                                          _notice(
                                              context,
                                              'Verification email sent.',
                                              'تم إرسال بريد التحقق.');
                                      }),
                              child: Text(_text(context, 'Resend verification',
                                  'إعادة إرسال التأكيد')),
                            ),
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _auth(widget.service.auth.signOut),
                              child: Text(
                                  _text(context, 'Sign out', 'تسجيل الخروج')),
                            ),
                          ]),
              ),
              if (_busy) const LinearProgressIndicator(),
            ],
          );
        },
      );
}

class _HouseholdDirectory extends StatefulWidget {
  const _HouseholdDirectory(
      {super.key, required this.service, required this.user});
  final HouseholdFirebase service;
  final User user;

  @override
  State<_HouseholdDirectory> createState() => _HouseholdDirectoryState();
}

class _HouseholdDirectoryState extends State<_HouseholdDirectory>
    with WidgetsBindingObserver {
  late final _session = widget.service.session(widget.user);
  late var _households = _session.households();
  late var _pending = _session.store.outbox();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_run(_session.outbox.sync, reportError: false));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed)
      unawaited(_run(_session.outbox.sync, reportError: false));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action,
      {bool reportError = true}) async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted && reportError) {
        _notice(
            context,
            'Could not complete the change. Check the connection or invitation.',
            'تعذّر إكمال التغيير. تحقق من الاتصال أو الدعوة.');
      }
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _households = _session.households();
          _pending = _session.store.outbox();
        });
    }
  }

  Future<void> _create() async {
    final name = await _prompt(
        context, _text(context, 'Household name', 'اسم الأسرة'),
        limit: 70);
    if (name != null)
      await _run(() => _session.createHousehold(uuid.v4(), name));
  }

  Future<void> _join() async {
    final code = await _prompt(
        context, _text(context, 'Invitation code', 'كود الدعوة'),
        limit: 105, latin: true);
    if (code != null) await _run(() => _session.acceptInvite(code));
  }

  Future<void> _signOut() async {
    await _run(() async {
      // Pending changes remain under this login. Cached account content is discarded.
      await widget.service.auth.signOut();
      await _session.store.clearCache();
    });
  }

  @override
  Widget build(BuildContext context) => PageFramework(
        title: _text(context, 'Household sharing', 'المشاركة الأسرية'),
        capitalizeTitle: false,
        listWidgets: [
          ListTile(
            title: Text(widget.user.email ?? ''),
            trailing: TextButton(
                onPressed: _busy ? null : _signOut,
                child: Text(_text(context, 'Sign out', 'تسجيل الخروج'))),
          ),
          Wrap(alignment: WrapAlignment.center, spacing: 8, children: [
            FilledButton(
                onPressed: _busy ? null : _create,
                child: Text(_text(context, 'Create household', 'إنشاء أسرة'))),
            OutlinedButton(
                onPressed: _busy ? null : _join,
                child: Text(_text(context, 'Join with code', 'الانضمام بكود'))),
            TextButton(
                onPressed: _busy ? null : () => _run(_session.outbox.sync),
                child:
                    Text(_text(context, 'Sync changes', 'مزامنة التغييرات'))),
          ]),
          if (_busy) const LinearProgressIndicator(),
          _load(
              _pending,
              (context, items) => _OutboxList(
                    items: items,
                    onDiscard: _busy
                        ? null
                        : (id) => _run(() => _session.store.remove(id)),
                  )),
          _load(
              _households,
              (context, rows) => Column(children: [
                    if (rows.offline) _offline(context),
                    if (rows.items.isEmpty)
                      ListTile(
                          title: Text(_text(context, 'No households yet.',
                              'لا توجد أسر بعد.'))),
                    for (final space in rows.items)
                      ListTile(
                        title: Text(space.name),
                        subtitle: Text(space.isOwner
                            ? _text(context, 'Owner', 'مالك')
                            : _text(context, 'Member', 'عضو')),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _busy
                            ? null
                            : () async {
                                await _open<void>(
                                    context,
                                    _HouseholdAccountsPage(
                                        session: _session, space: space));
                                if (mounted)
                                  await _run(_session.outbox.sync,
                                      reportError: false);
                              },
                      ),
                  ])),
        ],
      );
}

class _HouseholdAccountsPage extends StatefulWidget {
  const _HouseholdAccountsPage({required this.session, required this.space});
  final HouseholdFirebaseSession session;
  final SharedHousehold space;

  @override
  State<_HouseholdAccountsPage> createState() => _HouseholdAccountsPageState();
}

typedef _AccountSeed = ({
  String name,
  String currency,
  int decimals,
  double balance
});

class _HouseholdAccountsPageState extends State<_HouseholdAccountsPage> {
  late var _accounts = widget.session.accounts(widget.space);
  bool _busy = false;

  Future<void> _createAccount({_AccountSeed? seed}) async {
    final account = await showDialog<SharedHouseholdAccount>(
      context: context,
      builder: (_) => _SharedAccountEditor(seed: seed),
    );
    if (!mounted || account == null) return;
    setState(() => _busy = true);
    try {
      await widget.session.createAccount(widget.space.id, account);
    } catch (_) {
      if (mounted)
        _notice(context, 'Could not create the account. Check connectivity.',
            'تعذّر إنشاء الحساب. تحقق من الاتصال.');
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _accounts = widget.session.accounts(widget.space);
        });
    }
  }

  Future<void> _copyOpening() async {
    final wallets = database.getFinancialInsightsAccounts();
    final wallet = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
            _text(context, 'Choose a personal account', 'اختر حسابًا شخصيًا')),
        scrollable: true,
        content: _load(
            wallets,
            (context, rows) =>
                Column(mainAxisSize: MainAxisSize.min, children: [
                  if (rows.isEmpty)
                    Text(_text(context, 'No active accounts.',
                        'لا توجد حسابات نشطة.')),
                  for (final row in rows)
                    ListTile(
                      title: Text(row.name),
                      subtitle: Text(row.currency.toUpperCase()),
                      onTap: () => Navigator.pop(context, row.id),
                    ),
                ])),
      ),
    );
    if (wallet == null || !mounted) return;
    try {
      final seed =
          await database.previewHouseholdWalletOpening(wallet, DateTime.now());
      if (!mounted) return;
      if (seed == null) {
        _notice(context, 'Choose an active account with a currency.',
            'اختر حسابًا نشطًا بعملة محددة.');
      } else {
        await _createAccount(seed: seed);
      }
    } catch (_) {
      if (mounted)
        _notice(context, 'Could not read the opening balance.',
            'تعذّر قراءة الرصيد الافتتاحي.');
    }
  }

  @override
  Widget build(BuildContext context) => PageFramework(
        title: widget.space.name,
        capitalizeTitle: false,
        listWidgets: [
          Wrap(alignment: WrapAlignment.center, spacing: 8, children: [
            if (widget.space.isOwner) ...[
              FilledButton(
                onPressed: _busy ? null : () => _createAccount(),
                child: Text(
                    _text(context, 'New shared account', 'حساب مشترك جديد')),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _copyOpening,
                child: Text(_text(context, 'Use personal opening balance',
                    'استخدام رصيد شخصي افتتاحي')),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _open<void>(
                        context,
                        _HouseholdPeoplePage(
                          session: widget.session,
                          space: widget.space,
                        )),
                child: Text(_text(
                    context, 'Members and invitations', 'الأعضاء والدعوات')),
              ),
            ],
            IconButton(
              tooltip: _text(context, 'Refresh accounts', 'تحديث الحسابات'),
              onPressed: _busy
                  ? null
                  : () => setState(
                      () => _accounts = widget.session.accounts(widget.space)),
              icon: const Icon(Icons.refresh),
            ),
          ]),
          if (_busy) const LinearProgressIndicator(),
          _load(
              _accounts,
              (context, rows) => Column(children: [
                    if (rows.offline) _offline(context),
                    if (rows.items.isEmpty)
                      ListTile(
                          title: Text(_text(
                              context,
                              'No shared accounts available.',
                              'لا توجد حسابات مشتركة متاحة.'))),
                    for (final account in rows.items)
                      ListTile(
                        title: Text(account.name),
                        subtitle: Text(
                            '${account.currency} · ${_roleLabel(context, account.role)}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          await _open<void>(
                              context,
                              _SharedLedgerPage(
                                space: widget.space,
                                account: account,
                                session: widget.session,
                              ));
                          if (mounted)
                            setState(() => _accounts =
                                widget.session.accounts(widget.space));
                        },
                      ),
                  ])),
        ],
      );
}

String _roleLabel(BuildContext context, SharedHouseholdRole role) =>
    switch (role) {
      SharedHouseholdRole.owner => _text(context, 'Owner', 'مالك'),
      SharedHouseholdRole.editor => _text(context, 'Can edit', 'يسمح بالتعديل'),
      SharedHouseholdRole.viewer => _text(context, 'View only', 'عرض فقط'),
    };

class _SharedAccountEditor extends StatefulWidget {
  const _SharedAccountEditor({this.seed});
  final _AccountSeed? seed;

  @override
  State<_SharedAccountEditor> createState() => _SharedAccountEditorState();
}

class _SharedAccountEditorState extends State<_SharedAccountEditor> {
  final _form = GlobalKey<FormState>();
  late var _name = widget.seed?.name ?? '';
  late var _currency = widget.seed?.currency ?? 'EGP';
  late var _decimals = widget.seed?.decimals ?? 2;
  late final _amount = TextEditingController(
      text: widget.seed == null
          ? '0'
          : widget.seed!.balance.toStringAsFixed(_decimals));

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title:
            Text(_text(context, 'Create shared account', 'إنشاء حساب مشترك')),
        scrollable: true,
        content: Form(
          key: _form,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (widget.seed != null)
              Text(_text(
                context,
                'The household receives the name, currency and opening balance shown here. Personal transactions stay on this device.',
                'تستقبل الأسرة الاسم والعملة والرصيد الافتتاحي الظاهر هنا. تبقى المعاملات الشخصية على جهازك.',
              )),
            TextFormField(
              initialValue: _name,
              maxLength: 70,
              decoration:
                  InputDecoration(labelText: _text(context, 'Name', 'الاسم')),
              onChanged: (value) => _name = value.trim(),
              validator: (_) => _name.isEmpty || _name.length > 70
                  ? _text(context, 'Enter a name up to 70 characters.',
                      'أدخل اسمًا حتى ٧٠ حرفًا.')
                  : null,
            ),
            TextFormField(
              initialValue: _currency,
              enabled: widget.seed == null,
              maxLength: 3,
              textDirection: TextDirection.ltr,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                  labelText: _text(context, 'Currency code', 'رمز العملة')),
              onChanged: (value) => _currency = value.trim().toUpperCase(),
              validator: (_) => RegExp(r'^[A-Z]{3}$').hasMatch(_currency)
                  ? null
                  : _text(context, 'Use three letters, for example EGP.',
                      'استخدم ثلاثة أحرف، مثل EGP.'),
            ),
            DropdownButtonFormField<int>(
              initialValue: _decimals,
              decoration: InputDecoration(
                  labelText:
                      _text(context, 'Decimal places', 'الخانات العشرية')),
              items: [
                for (var count = 0; count <= 3; count++)
                  DropdownMenuItem(value: count, child: Text('$count')),
              ],
              onChanged: widget.seed != null
                  ? null
                  : (value) {
                      if (value != null) setState(() => _decimals = value);
                    },
            ),
            TextFormField(
              controller: _amount,
              textDirection: TextDirection.ltr,
              keyboardType: const TextInputType.numberWithOptions(
                  decimal: true, signed: true),
              decoration: InputDecoration(
                  labelText:
                      _text(context, 'Opening balance', 'الرصيد الافتتاحي')),
              validator: (_) =>
                  parseHouseholdMinor(_amount.text, _decimals) == null
                      ? _text(context, 'Enter a valid opening balance.',
                          'أدخل رصيدًا افتتاحيًا صالحًا.')
                      : null,
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_text(context, 'Cancel', 'إلغاء'))),
          FilledButton(
              onPressed: () {
                if (!_form.currentState!.validate()) return;
                Navigator.pop(
                    context,
                    SharedHouseholdAccount(
                      id: uuid.v4(),
                      name: _name,
                      currency: _currency,
                      decimals: _decimals,
                      opening: parseHouseholdMinor(_amount.text, _decimals)!,
                      role: SharedHouseholdRole.owner,
                    ));
              },
              child: Text(_text(context, 'Create', 'إنشاء'))),
        ],
      );
}

class _HouseholdPeoplePage extends StatefulWidget {
  const _HouseholdPeoplePage({required this.session, required this.space});
  final HouseholdFirebaseSession session;
  final SharedHousehold space;

  @override
  State<_HouseholdPeoplePage> createState() => _HouseholdPeoplePageState();
}

class _HouseholdPeoplePageState extends State<_HouseholdPeoplePage> {
  late var _members = widget.session.members(widget.space.id);
  late var _invites = widget.session.openInvites(widget.space.id);
  bool _busy = false;

  void _reload() {
    _members = widget.session.members(widget.space.id);
    _invites = widget.session.openInvites(widget.space.id);
  }

  Future<void> _update(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted)
        _notice(
            context, 'Could not update the household.', 'تعذّر تحديث الأسرة.');
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _reload();
        });
    }
  }

  Future<void> _invite() async {
    final email = await _prompt(
        context, _text(context, 'Email to invite', 'البريد المراد دعوته'),
        limit: 254,
        latin: true,
        validate: (value) => _checkEmail(context, value));
    if (email == null || !mounted) return;
    await _update(
        () => widget.session.createInvite(widget.space.id, uuid.v4(), email));
  }

  Future<void> _copyInvite(SharedInvite invite) async {
    try {
      await Clipboard.setData(
          ClipboardData(text: '${widget.space.id}/${invite.id}'));
      if (mounted)
        _notice(context, 'Invitation code copied.', 'تم نسخ كود الدعوة.');
    } catch (_) {
      if (mounted)
        _notice(context, 'Could not copy the invitation.', 'تعذّر نسخ الدعوة.');
    }
  }

  Future<void> _revokeMember(SharedMember member) async {
    final ok = await _confirm(context,
        _text(context, 'Revoke household access?', 'إلغاء وصول العضو؟'),
        description: member.email);
    if (ok && mounted)
      await _update(
          () => widget.session.revokeMember(widget.space.id, member.id));
  }

  @override
  Widget build(BuildContext context) => PageFramework(
        title: _text(context, 'Members and invitations', 'الأعضاء والدعوات'),
        capitalizeTitle: false,
        listWidgets: [
          Wrap(alignment: WrapAlignment.center, children: [
            FilledButton(
                onPressed: _busy ? null : _invite,
                child: Text(_text(context, 'Create invitation', 'إنشاء دعوة'))),
            IconButton(
              tooltip: _text(context, 'Refresh', 'تحديث'),
              icon: const Icon(Icons.refresh),
              onPressed: _busy ? null : () => setState(_reload),
            ),
          ]),
          if (_busy) const LinearProgressIndicator(),
          _load(
              _invites,
              (context, rows) => Column(children: [
                    if (rows.isEmpty)
                      ListTile(
                          title: Text(_text(context, 'No open invitations.',
                              'لا توجد دعوات مفتوحة.'))),
                    for (final invite in rows)
                      ListTile(
                        title: Text(invite.email),
                        subtitle: Text(invite.expires.isAfter(DateTime.now())
                            ? '${_text(context, 'Expires', 'تنتهي')} ${MaterialLocalizations.of(context).formatShortDate(invite.expires)}'
                            : _text(context, 'Expired', 'انتهت')),
                        trailing: Wrap(spacing: 4, children: [
                          IconButton(
                            tooltip: _text(context, 'Copy invitation code',
                                'نسخ كود الدعوة'),
                            icon: const Icon(Icons.copy),
                            onPressed:
                                _busy || !invite.expires.isAfter(DateTime.now())
                                    ? null
                                    : () => _copyInvite(invite),
                          ),
                          IconButton(
                            tooltip: _text(
                                context, 'Cancel invitation', 'إلغاء الدعوة'),
                            icon: const Icon(Icons.close),
                            onPressed: _busy
                                ? null
                                : () => _update(() => widget.session
                                    .revokeInvite(widget.space.id, invite.id)),
                          ),
                        ]),
                      ),
                  ])),
          _load(
              _members,
              (context, rows) => Column(children: [
                    if (rows.isEmpty)
                      ListTile(
                          title: Text(_text(context, 'No invited members yet.',
                              'لا يوجد أعضاء مدعوون بعد.'))),
                    for (final member in rows)
                      ListTile(
                        title: Text(member.email),
                        subtitle: Text(member.active
                            ? _text(context, 'Active member', 'عضو نشط')
                            : _text(
                                context, 'Access revoked', 'تم إلغاء الوصول')),
                        trailing: member.active
                            ? IconButton(
                                tooltip: _text(
                                    context, 'Revoke access', 'إلغاء الوصول'),
                                onPressed:
                                    _busy ? null : () => _revokeMember(member),
                                icon: const Icon(Icons.person_remove_outlined),
                              )
                            : null,
                      ),
                  ])),
        ],
      );
}

class _SharedLedgerPage extends StatefulWidget {
  const _SharedLedgerPage(
      {required this.space, required this.account, required this.session});
  final SharedHousehold space;
  final SharedHouseholdAccount account;
  final HouseholdFirebaseSession session;

  @override
  State<_SharedLedgerPage> createState() => _SharedLedgerPageState();
}

class _SharedLedgerPageState extends State<_SharedLedgerPage>
    with WidgetsBindingObserver {
  late var _entries =
      widget.session.entries(widget.space.id, widget.account.id);
  late var _pending = _pendingForAccount();
  bool _saving = false;
  bool _syncing = false;
  int _visible = 40;

  StreamSubscription<HouseholdRead<SharedHouseholdEntry>>? _live;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscribe();
  }

  void _subscribe() {
    _live ??=
        widget.session.liveEntries(widget.space.id, widget.account.id).listen(
      (snapshot) {
        if (mounted) setState(() => _entries = Future.value(snapshot));
      },
      onError: (Object _) {
        _live = null;
        if (mounted) {
          setState(() => _entries =
              widget.session.entries(widget.space.id, widget.account.id));
        }
      },
      onDone: () => _live = null,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_sync());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_live?.cancel());
    super.dispose();
  }

  Future<List<HouseholdOutboxItem>> _pendingForAccount() async => [
        for (final item in await widget.session.store.outbox())
          if (item.change.space == widget.space.id &&
              item.change.account == widget.account.id)
            item,
      ];

  String _amount(int minor) =>
      '${displayHouseholdMinor(minor, widget.account.decimals)} ${widget.account.currency}';

  Future<void> _sync() async {
    if (_syncing || !mounted) return;
    setState(() => _syncing = true);
    _subscribe();
    try {
      await widget.session.outbox.sync();
    } catch (_) {
      if (mounted)
        _notice(context, 'Could not sync now. Check the connection.',
            'تعذّرت المزامنة الآن. تحقق من الاتصال.');
    } finally {
      if (mounted)
        setState(() {
          _syncing = false;
          _entries = widget.session.entries(widget.space.id, widget.account.id);
          _pending = _pendingForAccount();
        });
    }
  }

  Future<void> _stage(SharedHouseholdEntry entry,
      {bool deleted = false}) async {
    if (_saving || !mounted) return;
    setState(() => _saving = true);
    try {
      await widget.session.store.stage(HouseholdMutation(
        id: entry.revision == 0 ? entry.id : uuid.v4(),
        space: widget.space.id,
        account: widget.account.id,
        generation: widget.account.generation,
        entry: entry,
        deleted: deleted,
      ));
      if (mounted) {
        setState(() => _pending = _pendingForAccount());
        unawaited(_sync());
      }
    } catch (_) {
      if (mounted)
        _notice(
            context,
            'Could not queue this change. Check for an existing draft.',
            'تعذّر وضع التغيير في قائمة الانتظار. تحقق إن كانت هناك مسودة سابقة.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit([SharedHouseholdEntry? entry]) async {
    final draft = await showDialog<SharedHouseholdEntry>(
      context: context,
      builder: (_) =>
          _SharedEntryEditor(account: widget.account, initial: entry),
    );
    if (draft != null && mounted) await _stage(draft);
  }

  Future<void> _delete(SharedHouseholdEntry entry) async {
    final ok = await _confirm(
        context, _text(context, 'Delete shared entry?', 'حذف القيد المشترك؟'),
        description: entry.title);
    if (ok && mounted) await _stage(entry, deleted: true);
  }

  Future<void> _discard(String id) async {
    if (_syncing) return;
    try {
      await widget.session.store.remove(id);
      if (mounted) setState(() => _pending = _pendingForAccount());
    } catch (_) {
      if (mounted)
        _notice(context, 'Could not discard the saved change.',
            'تعذّر استبعاد التغيير المحفوظ.');
    }
  }

  @override
  Widget build(BuildContext context) => PageFramework(
        title: widget.account.name,
        capitalizeTitle: false,
        listWidgets: [
          Wrap(alignment: WrapAlignment.center, spacing: 8, children: [
            if (widget.account.role.canEdit)
              FilledButton(
                onPressed: _saving ? null : () => _edit(),
                child:
                    Text(_text(context, 'Add shared entry', 'إضافة قيد مشترك')),
              ),
            if (widget.space.isOwner)
              OutlinedButton(
                onPressed: () => _open<void>(
                    context,
                    _HouseholdAccessPage(
                      session: widget.session,
                      space: widget.space,
                      account: widget.account,
                    )),
                child: Text(_text(context, 'Account access', 'صلاحيات الحساب')),
              ),
            IconButton(
              tooltip: _text(context, 'Sync and refresh', 'مزامنة وتحديث'),
              icon: const Icon(Icons.sync),
              onPressed: _syncing ? null : _sync,
            ),
          ]),
          if (_syncing || _saving) const LinearProgressIndicator(),
          _load(
              _pending,
              (context, items) => _OutboxList(
                    items: items,
                    onDiscard: _syncing ? null : _discard,
                  )),
          _load(_entries, (context, snapshot) {
            final balance = snapshot.items.fold(
                widget.account.opening, (sum, entry) => sum + entry.minor);
            return Column(children: [
              if (snapshot.offline) _offline(context),
              ListTile(
                title:
                    Text(_text(context, 'Confirmed balance', 'الرصيد المؤكد')),
                trailing:
                    Text(_amount(balance), textDirection: TextDirection.ltr),
                subtitle: Text(
                    '${_text(context, 'Opening balance', 'الرصيد الافتتاحي')} · ${_amount(widget.account.opening)}'),
              ),
              if (snapshot.items.isEmpty)
                ListTile(
                    title: Text(_text(context, 'No shared entries.',
                        'لا توجد قيود مشتركة.'))),
              for (final item in snapshot.items.take(_visible))
                ListTile(
                  title: Text(item.title),
                  subtitle: Text('${item.day} · ${_amount(item.minor)}'),
                  trailing: widget.account.role.canEdit
                      ? PopupMenuButton<bool>(
                          enabled: !_saving,
                          onSelected: (remove) =>
                              remove ? _delete(item) : _edit(item),
                          itemBuilder: (context) => [
                            PopupMenuItem(
                                value: false,
                                child: Text(_text(context, 'Edit', 'تعديل'))),
                            PopupMenuItem(
                                value: true,
                                child: Text(_text(context, 'Delete', 'حذف'))),
                          ],
                        )
                      : null,
                ),
              if (_visible < snapshot.items.length)
                TextButton(
                    onPressed: () => setState(() => _visible += 40),
                    child: Text(_text(
                        context, 'Show more entries', 'عرض المزيد من القيود'))),
            ]);
          }),
        ],
      );
}

class _OutboxList extends StatelessWidget {
  const _OutboxList({required this.items, required this.onDiscard});
  final List<HouseholdOutboxItem> items;
  final Future<void> Function(String)? onDiscard;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return ExpansionTile(
      initiallyExpanded: true,
      title: Text(_text(context, 'Saved changes on this device',
          'تغييرات محفوظة على هذا الجهاز')),
      children: [
        for (final item in items)
          ListTile(
            title: Text(item.change.entry.title),
            subtitle: Text(switch (item.delivery) {
              HouseholdDelivery.pending =>
                _text(context, 'Waiting to sync', 'في انتظار المزامنة'),
              HouseholdDelivery.conflict => _text(
                  context,
                  'Changed elsewhere. Refresh the ledger before editing again.',
                  'تغيّر القيد على جهاز آخر. حدّث السجل قبل التعديل مجددًا.'),
              HouseholdDelivery.denied => _text(
                  context,
                  'Server declined access to this edit.',
                  'رفض الخادم صلاحية هذا التعديل.'),
            }),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              tooltip: _text(
                  context, 'Discard queued change', 'استبعاد التغيير المعلق'),
              onPressed: onDiscard == null
                  ? null
                  : () async {
                      final ok = await _confirm(
                          context,
                          _text(context, 'Discard this saved change?',
                              'استبعاد التغيير المحفوظ؟'),
                          description: item.change.entry.title);
                      if (ok && context.mounted)
                        await onDiscard!(item.change.id);
                    },
            ),
          ),
      ],
    );
  }
}

class _SharedEntryEditor extends StatefulWidget {
  const _SharedEntryEditor({required this.account, this.initial});
  final SharedHouseholdAccount account;
  final SharedHouseholdEntry? initial;

  @override
  State<_SharedEntryEditor> createState() => _SharedEntryEditorState();
}

class _SharedEntryEditorState extends State<_SharedEntryEditor> {
  final _form = GlobalKey<FormState>();
  late var _title = widget.initial?.title ?? '';
  late var _income = (widget.initial?.minor ?? 0) > 0;
  late var _date = widget.initial == null
      ? DateTime.now()
      : DateTime.parse(widget.initial!.day);
  late var _amount = widget.initial == null
      ? ''
      : displayHouseholdMinor(
          widget.initial!.minor.abs(), widget.account.decimals);

  Future<void> _chooseDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(1),
      lastDate: DateTime(9999, 12, 31),
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.initial == null
            ? _text(context, 'New shared entry', 'قيد مشترك جديد')
            : _text(context, 'Edit shared entry', 'تعديل قيد مشترك')),
        scrollable: true,
        content: Form(
          key: _form,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
              initialValue: _title,
              maxLength: 100,
              decoration: InputDecoration(
                  labelText: _text(context, 'Description', 'الوصف')),
              onChanged: (value) => _title = value.trim(),
              validator: (_) => _title.isEmpty
                  ? _text(context, 'Enter a description.', 'أدخل وصفًا.')
                  : null,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _income,
              title: Text(_income
                  ? _text(context, 'Income', 'دخل')
                  : _text(context, 'Expense', 'مصروف')),
              onChanged: (value) => setState(() => _income = value),
            ),
            TextFormField(
              initialValue: _amount,
              textDirection: TextDirection.ltr,
              keyboardType: TextInputType.numberWithOptions(
                  decimal: widget.account.decimals != 0),
              decoration: InputDecoration(
                  labelText: _text(context, 'Amount', 'المبلغ'),
                  suffixText: widget.account.currency),
              onChanged: (value) => _amount = value,
              validator: (_) =>
                  (parseHouseholdMinor(_amount, widget.account.decimals) ??
                              0) <=
                          0
                      ? _text(context, 'Enter a positive amount.',
                          'أدخل مبلغًا موجبًا.')
                      : null,
            ),
            TextButton.icon(
                onPressed: _chooseDay,
                icon: const Icon(Icons.calendar_today_outlined),
                label: Text(
                    MaterialLocalizations.of(context).formatMediumDate(_date))),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_text(context, 'Cancel', 'إلغاء'))),
          FilledButton(
              onPressed: () {
                if (!_form.currentState!.validate()) return;
                final amount =
                    parseHouseholdMinor(_amount, widget.account.decimals)!;
                Navigator.pop(
                    context,
                    SharedHouseholdEntry(
                      id: widget.initial?.id ?? uuid.v4(),
                      title: _title,
                      minor: _income ? amount : -amount,
                      day: householdDay(_date),
                      revision: widget.initial?.revision ?? 0,
                    ));
              },
              child: Text(_text(context, 'Queue for sync', 'حفظ للمزامنة'))),
        ],
      );
}

class _HouseholdAccessPage extends StatefulWidget {
  const _HouseholdAccessPage(
      {required this.session, required this.space, required this.account});
  final HouseholdFirebaseSession session;
  final SharedHousehold space;
  final SharedHouseholdAccount account;

  @override
  State<_HouseholdAccessPage> createState() => _HouseholdAccessPageState();
}

class _HouseholdAccessPageState extends State<_HouseholdAccessPage> {
  late var _members = _loadMembers();
  bool _busy = false;

  Future<List<({SharedMember member, SharedHouseholdRole? role})>>
      _loadMembers() async {
    final members = await widget.session.members(widget.space.id);
    final grants = await widget.session.grants(widget.space.id,
        widget.account.id, members.where((member) => member.active));
    return [
      for (final member in members)
        if (member.active) (member: member, role: grants[member.id]),
    ];
  }

  Future<void> _update(SharedMember member, SharedHouseholdRole? role) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.session
          .setGrant(widget.space.id, widget.account.id, member, role);
    } catch (_) {
      if (mounted)
        _notice(context, 'Could not save account access.',
            'تعذّر حفظ صلاحية الحساب.');
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _members = _loadMembers();
        });
    }
  }

  @override
  Widget build(BuildContext context) => PageFramework(
        title: _text(context, 'Account access', 'صلاحيات الحساب'),
        capitalizeTitle: false,
        listWidgets: [
          if (_busy) const LinearProgressIndicator(),
          _load(
              _members,
              (context, rows) => Column(children: [
                    if (rows.isEmpty)
                      ListTile(
                          title: Text(_text(context, 'Invite a member first.',
                              'ادعُ عضوًا أولًا.'))),
                    for (final row in rows)
                      ListTile(
                        title: Text(row.member.email),
                        subtitle: DropdownButton<SharedHouseholdRole>(
                          value: row.role,
                          hint:
                              Text(_text(context, 'No access', 'بدون صلاحية')),
                          isExpanded: true,
                          items: [
                            DropdownMenuItem(
                                child: Text(_text(
                                    context, 'No access', 'بدون صلاحية'))),
                            for (final role in [
                              SharedHouseholdRole.viewer,
                              SharedHouseholdRole.editor
                            ])
                              DropdownMenuItem(
                                  value: role,
                                  child: Text(_roleLabel(context, role))),
                          ],
                          onChanged: _busy
                              ? null
                              : (role) => _update(row.member, role),
                        ),
                      ),
                  ])),
        ],
      );
}
