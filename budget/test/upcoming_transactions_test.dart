import 'package:flutter_test/flutter_test.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/upcomingTransactionsFunctions.dart';

void main() {
  group('nextRecurringDate calendar boundaries', () {
    test('monthly recurrence clamps January 31 to February', () {
      final next = nextRecurringDate(
        DateTime(2025, 1, 31, 9, 30),
        BudgetReoccurence.monthly,
        1,
      );
      expect(next, DateTime(2025, 2, 28, 9, 30));
    });

    test('monthly recurrence respects leap year', () {
      final next = nextRecurringDate(
        DateTime(2024, 1, 31, 9, 30),
        BudgetReoccurence.monthly,
        1,
      );
      expect(next, DateTime(2024, 2, 29, 9, 30));
    });

    test('yearly leap-day recurrence clamps to February 28', () {
      final next = nextRecurringDate(
        DateTime(2024, 2, 29, 12),
        BudgetReoccurence.yearly,
        1,
      );
      expect(next, DateTime(2025, 2, 28, 12));
    });

    test('invalid recurrence period is rejected', () {
      expect(
        nextRecurringDate(
          DateTime(2025, 1, 1),
          BudgetReoccurence.monthly,
          0,
        ),
        isNull,
      );
    });
  });
}
