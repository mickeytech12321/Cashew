import 'package:budget/database/tables.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

late String clientID;
late FinanceDatabase database;
late SharedPreferences sharedPreferences;
final uuid = Uuid();

Future<void> postDueBankCertificatePayouts(BuildContext context) async {
  final arabic = Localizations.localeOf(context).languageCode == 'ar';
  try {
    await database.postAutomaticCertificatePayouts(DateTime.now(),
        arabic: arabic);
  } catch (_) {
    debugPrint('Could not post due bank certificate payouts.');
  }
}
