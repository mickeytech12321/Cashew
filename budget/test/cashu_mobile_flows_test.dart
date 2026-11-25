import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/pages/addWalletPage.dart';
import 'package:budget/pages/cashuAddAssetPage.dart';
import 'package:budget/pages/homePage/cashuWalletDashboard.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/widgets/openPopup.dart' show RoutesToPopAfterDelete;
import 'package:budget/pages/settingsPage.dart';
import 'package:budget/struct/currencyFunctions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/settings.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> mount(
  WidgetTester tester,
  Widget page,
  List<TransactionWallet> wallets, {
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(Provider<AllWallets>.value(
    value: AllWallets(
      list: wallets,
      indexedByPk: {for (final wallet in wallets) wallet.walletPk: wallet},
    ),
    child: MaterialApp(
      theme: getLightTheme(),
      locale: locale,
      supportedLocales: const [Locale('en'), Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: page,
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> disposeFixture(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  final closed = database.close();
  await tester.pump(const Duration(seconds: 1));
  await closed;
}

void main() {
  setUp(() async {
    database = FinanceDatabase(NativeDatabase.memory());
    SharedPreferences.setMockInitialValues({});
    sharedPreferences = await SharedPreferences.getInstance();
    appStateSettings = await getDefaultPreferences();
    appStateSettings['selectedWalletPk'] = 'missing-after-restore';
    currenciesJSON = {
      'egp': {'Code': 'EGP', 'Symbol': 'EGP', 'Currency': 'Egyptian pound'},
    };
  });

  Future<TransactionWallet> wallet(String id, String name, int order) async {
    await database.into(database.wallets).insert(WalletsCompanion.insert(
          walletPk: Value(id),
          name: name,
          currency: const Value('egp'),
          order: order,
        ));
    return database.getWalletInstance(id);
  }

  testWidgets('editing just the account type saves the correct wallet', (tester) async {
    final checking = await wallet('checking', 'Checking', 0);
    final other = await wallet('other', 'Other account', 1);
    await database.saveAccountDetails(walletPk: other.walletPk, accountType: 'cash');
    await mount(
      tester,
      AddWalletPage(wallet: checking, routesToPopAfterDelete: RoutesToPopAfterDelete.PreventDelete),
      [checking, other],
    );

    final type = find.byType(DropdownButtonFormField<String>);
    await tester.ensureVisible(type);
    await tester.tap(type);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bank account').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('save-changes').last);
    await tester.pump(const Duration(milliseconds: 400));
    expect((await database.getAccountDetails(checking.walletPk))?['account_type'], 'bank');
    expect((await database.getAccountDetails(other.walletPk))?['account_type'], 'cash');
    await disposeFixture(tester);
  });

  testWidgets('More opens InstaPay with a missing saved wallet and saves both legs and fee',
      (tester) async {
    final checking = await wallet('checking', 'Checking', 0);
    final other = await wallet('other', 'Other account', 1);
    await mount(
        tester, const Scaffold(body: SingleChildScrollView(child: MorePages())), [checking, other]);
    await tester.tap(find.text('transfer-balance'));
    await tester.pumpAndSettle();

    final accounts = find.byType(DropdownButtonFormField<String>);
    expect(find.text('From account'), findsOneWidget);
    expect(find.textContaining('Checking'), findsOneWidget);
    await tester.tap(accounts.at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Other account').last);
    await tester.pumpAndSettle();
    final amount = find.widgetWithText(TextField, 'Transfer amount');
    await tester.enterText(amount, '100');
    await tester.pumpAndSettle();
    final instaPay = find.widgetWithText(SwitchListTile, 'InstaPay transfer');
    await tester.ensureVisible(instaPay);
    await tester.tap(instaPay);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save transfer'));
    await tester.pump(const Duration(milliseconds: 400));

    final entries = await database.select(database.transactions).get();
    expect(entries.map((row) => (row.walletFk, row.amount)),
        unorderedEquals([('checking', -100.0), ('other', 100.0), ('checking', -.50)]));
    await disposeFixture(tester);
  });

  testWidgets('a paid expense previews and saves the total including the InstaPay fee', (tester) async {
    final checking = await wallet('checking', 'Checking', 0);
    await database.into(database.categories).insert(CategoriesCompanion.insert(
      categoryPk: const Value('shopping'), name: 'Shopping', order: 0,
    ));
    await mount(tester, AddTransactionPage(
      initialInstaPay: true,
      selectedWallet: checking,
      selectedAmount: 1000,
      selectedTitle: 'Payment',
      selectedCategory: await database.getCategoryInstance('shopping'),
      selectedIncome: false,
      routesToPopAfterDelete: RoutesToPopAfterDelete.None,
      startInitialAddTransactionSequence: false,
    ), [checking]);

    expect(find.textContaining('Total debit'), findsOneWidget);
    await tester.tap(find.text('add-transaction').last);
    await tester.pumpAndSettle();
    final payments = await database.getAllTransactionsFromWallet(checking.walletPk);
    expect(payments.single.amount, -1001);
    expect((await database.getInstaPayExpense(payments.single.transactionPk))?.principal, 1000);
    await disposeFixture(tester);
  });

  testWidgets('banking tools link card messages to an account at mobile width', (tester) async {
    final checking = await wallet('checking', 'Checking', 0);
    await mount(tester,
        const Scaffold(body: SingleChildScrollView(child: MorePages())),
        [checking]);
    await tester.tap(find.text('Financial tools'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Link card messages'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Checking · EGP').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '١٢٣٤');
    await tester.tap(find.text('Link card'));
    await tester.pumpAndSettle();
    expect(await database.suggestImportedCardWallet('1234', 'egp'), 'checking');
    await disposeFixture(tester);
  });

  testWidgets('dashboard opens certificates, and dark mode is accessible from its toolbar', (tester) async {
    final checking = await wallet('checking', 'Checking', 0);
    await mount(tester, Scaffold(body: CashuWalletDashboard(today: DateTime(2026, 11, 25))), [checking]);
    expect(find.text('My wallet'), findsOneWidget);
    expect(find.text('All EGP accounts'), findsOneWidget);
    await tester.tap(find.byTooltip('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(appStateSettings['theme'], 'dark');
    await tester.tap(find.text('Certificates'));
    await tester.pumpAndSettle();
    expect(find.text('Add a certificate'), findsOneWidget);
    await disposeFixture(tester);
  });

  testWidgets('add-to-CashU opens a certificate directly and previews monthly interest', (tester) async {
    final checking = await wallet('checking', 'Checking', 0);
    await mount(tester, const CashuAddAssetPage(), [checking]);
    await tester.tap(find.text('Bank certificate'));
    await tester.pumpAndSettle();
    final principal = find.widgetWithText(TextFormField, 'Principal');
    await tester.ensureVisible(principal);
    await tester.enterText(principal, '100000');
    final mode = find.widgetWithText(SwitchListTile, 'Calculate from annual rate');
    await tester.ensureVisible(mode);
    await tester.tap(mode);
    await tester.pumpAndSettle();
    final rate = find.widgetWithText(TextFormField, 'Annual rate');
    await tester.ensureVisible(rate);
    await tester.enterText(rate, '21.5');
    await tester.pumpAndSettle();
    expect(find.text('1,791.67 EGP'), findsOneWidget);
    await disposeFixture(tester);
  });

  testWidgets('the Arabic certificate list opens the creation form in RTL', (tester) async {
    final checking = await wallet('checking', 'Checking', 0);
    await mount(tester,
        const Scaffold(body: SingleChildScrollView(child: MorePages())),
        [checking], locale: const Locale('ar'));
    await tester.tap(find.text('الأدوات المالية'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('الشهادات البنكية'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إضافة شهادة'));
    await tester.pumpAndSettle();

    final title = find.text('اسم الشهادة');
    expect(title, findsOneWidget);
    expect(Directionality.of(tester.element(title)), ui.TextDirection.rtl);
    expect(find.text('العائد ينزل على حساب'), findsOneWidget);
    await disposeFixture(tester);
  });

  testWidgets('the Add credit card shortcut opens the credit fields', (tester) async {
    final checking = await wallet('checking', 'Checking', 0);
    await mount(tester,
        const Scaffold(body: SingleChildScrollView(child: MorePages())),
        [checking]);
    await tester.tap(find.text('Financial tools'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add credit card'));
    await tester.pumpAndSettle();

    expect(find.text('Credit card'), findsOneWidget);
    expect(find.text('Credit limit'), findsOneWidget);
    await disposeFixture(tester);
  });

  testWidgets('Arabic settings search finds backup and appearance', (tester) async {
    await mount(tester, const Scaffold(body: SettingsPageContent()), [],
        locale: const Locale('ar'));
    expect(find.text('المظهر'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'استعادة');
    await tester.pumpAndSettle();
    expect(find.text('النسخ ونقل البيانات'), findsOneWidget);
    expect(find.text('المظهر'), findsNothing);
    await tester.enterText(find.byType(TextField), 'ثيم');
    await tester.pumpAndSettle();
    await tester.tap(find.text('المظهر'));
    await tester.pumpAndSettle();
    expect(find.text('أسود خالص'), findsOneWidget);
    expect(Directionality.of(tester.element(find.text('أسود خالص'))), ui.TextDirection.rtl);
    await tester.tap(find.text('أسود خالص'));
    await tester.pumpAndSettle();
    expect(appStateSettings['theme'], 'black');
    expect(getDarkTheme().scaffoldBackgroundColor, Colors.black);
    await disposeFixture(tester);
  });
}
