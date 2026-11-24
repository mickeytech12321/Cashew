import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'reopens a partial version 47 schema and preserves local data',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cashew-schema-test',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/budget.sqlite');

      final original = FinanceDatabase(NativeDatabase(file));
      try {
        await original.savePlanningScenario(
          scenarioPk: 'scenario',
          name: 'Existing plan',
          baseDate: DateTime(2026, 11, 24),
          horizonDays: 7,
          startingBalance: 100,
        );
        await original.customStatement('DROP TABLE credit_card_details');
      } finally {
        await original.close();
      }

      final reopened = FinanceDatabase(NativeDatabase(file));
      addTearDown(reopened.close);
      expect(await reopened.getCreditCardDetails('missing'), isNull);
      final plan = await reopened.calculatePlanningScenario('scenario');
      expect(plan.single['balance'], 100);
    },
  );

  test(
    'forecast starts at the base balance and skips earlier occurrences',
    () async {
      final database = FinanceDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final base = DateTime(2026, 11, 24);
      await database.savePlanningScenario(
        scenarioPk: 'scenario',
        name: 'Weekly plan',
        baseDate: base,
        horizonDays: 7,
        startingBalance: 100,
      );
      await database.savePlanningScenarioItem(
        itemPk: 'past-bill',
        scenarioPk: 'scenario',
        name: 'Past bill',
        amount: 30,
        income: false,
        firstDate: base.subtract(const Duration(days: 1)),
      );
      await database.savePlanningScenarioItem(
        itemPk: 'weekly-bill',
        scenarioPk: 'scenario',
        name: 'Weekly bill',
        amount: 20,
        income: false,
        firstDate: base.subtract(const Duration(days: 7)),
        recurrenceDays: 7,
      );
      final forecast = await database.calculatePlanningScenario('scenario');
      expect(forecast.map((point) => point['balance']), [100, 80, 60]);
      expect(forecast.first['date'], base);
    },
  );
}
