import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/pages/addWalletPage.dart';
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
