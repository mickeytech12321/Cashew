import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart' show getWelcomeMessage, pushRoute;
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/pages/bankCertificatesPage.dart';
import 'package:budget/pages/cashuAddAssetPage.dart';
import 'package:budget/pages/editHomePage.dart';
import 'package:budget/pages/editWalletsPage.dart';
import 'package:budget/pages/financialAssistantPage.dart';
import 'package:budget/pages/homePage/homePageUsername.dart' show PartyHat;
import 'package:budget/pages/settingsPage.dart' show enterNameBottomSheet;
import 'package:budget/pages/homePage/homePageWalletSwitcher.dart'
    show EditHomePagePinnedWalletsPopup;
import 'package:budget/pages/walletDetailsPage.dart';
import 'package:budget/pages/wealthAssetsPage.dart';
import 'package:budget/struct/accountTypes.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/cashuSurfaces.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

class CashuWalletDashboard extends StatefulWidget {
  const CashuWalletDashboard({super.key, required this.today});
  final DateTime today;

  @override
  State<CashuWalletDashboard> createState() => _CashuWalletDashboardState();
}

class _CashuWalletDashboardState extends State<CashuWalletDashboard> {
  int _monthOffset = 0;
  String? _scope;
  DateTime get _month =>
      DateTime(widget.today.year, widget.today.month - _monthOffset);
  late var _accounts =
      database.watchCashuOverviewAccounts(_month, widget.today);

  @override
  void didUpdateWidget(CashuWalletDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!DateUtils.isSameDay(widget.today, oldWidget.today)) {
      _accounts = database.watchCashuOverviewAccounts(_month, widget.today);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = CashuColors(context);
    final wallets = context.watch<AllWallets>();
    String label(String en, String ar) => cashuLabel(context, en, ar);
    final username = (appStateSettings['username'] as String?)?.trim() ?? '';
    final personalize =
        isHomeScreenSectionEnabled(context, 'showUsernameWelcomeBanner');
    final currencyByDefault = wallets
        .indexedByPk[appStateSettings['selectedWalletPk']]?.currency
        ?.trim()
        .toLowerCase();
    return Center(
        child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1040),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              if (personalize)
                IconButton(
                  tooltip: label('Edit display name', 'تعديل الاسم'),
                  padding: EdgeInsets.zero,
                  onPressed: () async {
                    await enterNameBottomSheet(context);
                    if (mounted) setState(() {});
                  },
                  icon: Image.asset('assets/icon/icon.png',
                      width: 35, height: 35),
                )
              else
                Image.asset('assets/icon/icon.png', width: 35, height: 35),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label('My wallet', 'محفظتي'),
                        style:
                            Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  color: colors.ink,
                                  fontWeight: FontWeight.w800,
                                )),
                    if (personalize && username.isNotEmpty)
                      PartyHat(
                        size: 17,
                        child: Text(
                          appStateSettings['enableGreetingMessage'] == true
                              ? '${getWelcomeMessage()} $username'
                              : username,
                          style: TextStyle(color: colors.muted),
                        ),
                      ),
                  ],
                ),
              ),
              _AppearanceButton(),
              IconButton(
                tooltip: label('Customize Home', 'تخصيص الرئيسية'),
                icon: const Icon(Icons.tune_rounded),
                onPressed: () => pushRoute(context, EditHomePage()),
              ),
            ]),
            const SizedBox(height: 12),
            StreamBuilder<List<CashuOverviewAccount>>(
              stream: _accounts,
              builder: (context, snapshot) {
                final accounts =
                    snapshot.data ?? const <CashuOverviewAccount>[];
                final activeCurrencies = {
                  for (final account in accounts) account.currency
                };
                final fallback = activeCurrencies.contains(currencyByDefault)
                    ? currencyByDefault!
                    : activeCurrencies.contains('egp')
                        ? 'egp'
                        : activeCurrencies.firstOrNull ?? 'egp';
                final scopes = <String, String>{
                  for (final code in activeCurrencies)
                    'currency:$code': code.isEmpty
                        ? label(
                            'Accounts without a currency', 'حسابات بدون عملة')
                        : label('All ${code.toUpperCase()} accounts',
                            'كل حسابات ${code.toUpperCase()}'),
                  for (final account in accounts)
                    'wallet:${account.id}': account.name,
                };
                final scope =
                    scopes.containsKey(_scope) ? _scope! : 'currency:$fallback';
                final scoped = accounts
                    .where((a) =>
                        scope == 'currency:${a.currency}' ||
                        scope == 'wallet:${a.id}')
                    .toList();
                final currency = scoped.firstOrNull?.currency ?? fallback;
                final spent =
                    scoped.fold(0.0, (total, item) => total + item.spent);
                final balance =
                    scoped.fold(0.0, (total, item) => total + item.balance);
                final locale = Localizations.localeOf(context).toString();

                return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      CashuGreenPanel(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(children: [
                                Expanded(
                                  child: PopupMenuButton<String>(
                                    initialValue: scope,
                                    tooltip: label('Choose account or currency',
                                        'اختار الحساب أو العملة'),
                                    enabled: scopes.isNotEmpty,
                                    onSelected: (value) =>
                                        setState(() => _scope = value),
                                    itemBuilder: (_) => [
                                      for (final entry in scopes.entries)
                                        PopupMenuItem(
                                            value: entry.key,
                                            child: Text(entry.value)),
                                    ],
                                    child: _OverviewFilter(scopes[scope] ??
                                        label('All accounts', 'كل الحسابات')),
                                  ),
                                ),
                                const SizedBox(width: 9),
                                PopupMenuButton<int>(
                                  initialValue: _monthOffset,
                                  tooltip: label('Choose month', 'اختار الشهر'),
                                  onSelected: (value) => setState(() {
                                    _monthOffset = value;
                                    _accounts =
                                        database.watchCashuOverviewAccounts(
                                            _month, widget.today);
                                  }),
                                  itemBuilder: (_) => [
                                    for (var i = 0; i < 12; i++)
                                      PopupMenuItem(
                                          value: i,
                                          child: Text(
                                              DateFormat.yMMM(locale).format(
                                            DateTime(widget.today.year,
                                                widget.today.month - i),
                                          ))),
                                  ],
                                  child: _OverviewFilter(
                                      DateFormat.yMMM(locale).format(_month)),
                                ),
                              ]),
                              const SizedBox(height: 22),
                              if (snapshot.hasError)
                                Text(
                                    label('Balances could not be loaded',
                                        'تعذّر تحميل الأرصدة'),
                                    style: const TextStyle(color: Colors.white))
                              else if (!snapshot.hasData)
                                const LinearProgressIndicator()
                              else ...[
                                _AmountLabel(
                                  label: label(
                                      'Monthly spending', 'مصروفات الشهر'),
                                  value: _money(context, spent, currency),
                                  large: true,
                                ),
                                const SizedBox(height: 13),
                                _AmountLabel(
                                  label:
                                      label('Balance today', 'رصيد النهارده'),
                                  value: _money(context, balance, currency),
                                ),
                              ],
                            ]),
                      ),
                      const SizedBox(height: 14),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        _OverviewAction(
                            Icons.add_rounded,
                            label('Transaction', 'معاملة'),
                            () => pushRoute(
                                context,
                                AddTransactionPage(
                                    routesToPopAfterDelete:
                                        RoutesToPopAfterDelete.None))),
                        _OverviewAction(
                            Icons.account_balance_wallet_outlined,
                            label('Add account', 'إضافة حساب'),
                            () =>
                                pushRoute(context, const CashuAddAssetPage())),
                        _OverviewAction(
                            Icons.workspace_premium_outlined,
                            label('Certificates', 'الشهادات'),
                            () => pushRoute(
                                context, const BankCertificatesPage())),
                        _OverviewAction(
                            Icons.insights_rounded,
                            label('Wealth', 'الثروة'),
                            () => pushRoute(context, const WealthAssetsPage())),
                        _OverviewAction(
                            Icons.auto_awesome_outlined,
                            label('Assistant', 'المساعد'),
                            () => pushRoute(
                                context, const FinancialAssistantPage())),
                      ]),
                    ]);
              },
            ),
          ],
        ),
      ),
    ));
  }
}

String _money(BuildContext context, double value, String currency) {
  final amount = NumberFormat.decimalPatternDigits(
    locale: Localizations.localeOf(context).toString(),
    decimalDigits: value == value.truncateToDouble() ? 0 : 2,
  ).format(value);
  return currency.isEmpty ? amount : '$amount ${currency.toUpperCase()}';
}

class CashuAccountStrip extends StatefulWidget {
  const CashuAccountStrip({super.key, required this.today});
  final DateTime today;

  @override
  State<CashuAccountStrip> createState() => _CashuAccountStripState();
}

class _CashuAccountStripState extends State<CashuAccountStrip> {
  late var _accounts =
      database.watchCashuOverviewAccounts(widget.today, widget.today);

  @override
  void didUpdateWidget(CashuAccountStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!DateUtils.isSameDay(widget.today, oldWidget.today)) {
      _accounts =
          database.watchCashuOverviewAccounts(widget.today, widget.today);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = CashuColors(context);
    final wallets = context.watch<AllWallets>();
    final arabic = Localizations.localeOf(context).languageCode == 'ar';
    String label(String en, String ar) => cashuLabel(context, en, ar);
    return StreamBuilder<List<CashuOverviewAccount>>(
      stream: _accounts,
      builder: (context, snapshot) {
        final accounts = snapshot.data ?? const <CashuOverviewAccount>[];
        final pins = accounts
            .where((item) =>
                wallets.indexedByPk[item.id]?.homePageWidgetDisplay?.contains(
                    HomePageWidgetDisplay.WalletSwitcher.index.toString()) ==
                true)
            .toList();
        final visible = pins.isEmpty ? accounts : pins;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            CashuSectionTitle(label('Accounts', 'الحسابات'),
                action: Wrap(children: [
                  IconButton(
                    icon: const Icon(Icons.push_pin_outlined, size: 19),
                    tooltip: label(
                        'Choose pinned accounts', 'اختار الحسابات المثبّتة'),
                    onPressed: () => openBottomSheet(
                        context,
                        EditHomePagePinnedWalletsPopup(
                          homePageWidgetDisplay:
                              HomePageWidgetDisplay.WalletSwitcher,
                        ),
                        useCustomController: true),
                  ),
                  TextButton(
                    onPressed: () => pushRoute(context, EditWalletsPage()),
                    child: Text(label('Manage', 'إدارة')),
                  ),
                ])),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final item in visible)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 10),
                    child: SizedBox(
                        width: 166,
                        child: CashuPanel(
                          highlighted:
                              appStateSettings['selectedWalletPk'] == item.id,
                          onTap: () => pushRoute(context,
                              WatchedWalletDetailsPage(walletPk: item.id)),
                          padding: const EdgeInsets.all(12),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CashuIconTile(cashuAccountIcon(item.type),
                                    size: 33),
                                const SizedBox(height: 8),
                                Text(item.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: colors.ink,
                                        fontWeight: FontWeight.w700)),
                                Text(
                                    accountTypeLabel(item.type, arabic: arabic),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: colors.muted, fontSize: 12)),
                                const SizedBox(height: 5),
                                Text(
                                    _money(
                                        context, item.balance, item.currency),
                                    style: TextStyle(
                                        color: colors.ink,
                                        fontWeight: FontWeight.w800)),
                              ]),
                        )),
                  ),
              ]),
            ),
          ]),
        );
      },
    );
  }
}

class _OverviewFilter extends StatelessWidget {
  const _OverviewFilter(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0x20ffffff),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
                child: Text(text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Color(0xffeff8f0),
                        fontWeight: FontWeight.w600))),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, color: Color(0xffd2efd7), size: 17),
          ]),
        ),
      );
}

class _AmountLabel extends StatelessWidget {
  const _AmountLabel(
      {required this.label, required this.value, this.large = false});
  final String label;
  final String value;
  final bool large;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Color(0xffc4dace))),
          const SizedBox(height: 3),
          Text(value,
              style: TextStyle(
                color: const Color(0xffeff8f0),
                fontWeight: FontWeight.w800,
                fontSize: large ? 38 : 19,
                height: 1.06,
                letterSpacing: large ? -1.2 : 0,
              )),
        ],
      );
}

class _OverviewAction extends StatelessWidget {
  const _OverviewAction(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: ActionChip(
        avatar: Icon(icon, size: 17, color: CashuColors(context).accent),
        label: Text(label),
        onPressed: onTap,
        backgroundColor: CashuColors(context).panel,
        side: BorderSide(color: CashuColors(context).border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
}

class _AppearanceButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    String label(String en, String ar) => cashuLabel(context, en, ar);
    return PopupMenuButton<String>(
      icon: Icon(Theme.of(context).brightness == Brightness.dark
          ? Icons.dark_mode_outlined
          : Icons.light_mode_outlined),
      tooltip: label('Appearance', 'المظهر'),
      initialValue: appStateSettings['theme'] as String?,
      onSelected: (theme) async {
        await updateSettings('forceFullDarkBackground', theme == 'black',
            updateGlobalState: false);
        await updateSettings('theme', theme, updateGlobalState: true);
      },
      itemBuilder: (_) => [
        PopupMenuItem(
            value: 'system', child: Text(label('Follow system', 'حسب الجهاز'))),
        PopupMenuItem(value: 'light', child: Text(label('Light', 'فاتح'))),
        PopupMenuItem(value: 'dark', child: Text(label('Dark', 'داكن'))),
        PopupMenuItem(
            value: 'black', child: Text(label('Pure black', 'أسود خالص'))),
      ],
    );
  }
}
