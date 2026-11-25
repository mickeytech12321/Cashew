import 'package:budget/pages/financialImportPage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final entry
      in {'en': TextDirection.ltr, 'ar': TextDirection.rtl}.entries) {
    testWidgets('Bank import label follows the ${entry.key} locale',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        locale: Locale(entry.key),
        supportedLocales: const [Locale('en'), Locale('ar')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Builder(builder: (context) {
          expect(Directionality.of(context), entry.value);
          return Text(FinancialImportPage.label(
            context,
            'Bank message import',
            'استيراد الرسائل البنكية',
          ));
        }),
      ));
      await tester.pumpAndSettle();
      expect(
          find.text(entry.key == 'ar'
              ? 'استيراد الرسائل البنكية'
              : 'Bank message import'),
          findsOneWidget);
    });
  }
}
