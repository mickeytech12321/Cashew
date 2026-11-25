import 'package:budget/struct/googleServiceConfiguration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default Google authorization only requests the backup scope', () {
    expect(requestedGoogleScopes(), [
      'https://www.googleapis.com/auth/drive.appdata',
    ]);
  });

  test('account-only sign-in does not request any Drive permission', () {
    expect(requestedGoogleScopes(backup: false), isEmpty);
    expect(requestedGoogleScopes(backup: false, attachments: true),
        ['https://www.googleapis.com/auth/drive.file']);
  });

  test('adding attachments does not grant Gmail or full Drive access', () {
    expect(requestedGoogleScopes(attachments: true), [
      'https://www.googleapis.com/auth/drive.appdata',
      'https://www.googleapis.com/auth/drive.file',
    ]);
  });

  test('mail permission is separate from Drive attachment access', () {
    expect(requestedGoogleScopes(mail: true), [
      'https://www.googleapis.com/auth/drive.appdata',
      'https://www.googleapis.com/auth/gmail.modify',
    ]);
  });

  test('Android OAuth configuration requires a Google client ID format', () {
    expect(
        isGoogleOAuthClientId('1234-demo.apps.googleusercontent.com'), isTrue);
    for (final invalid in [
      '',
      'AIzaExample',
      'GOCSPX-Example',
      'https://1234-demo.apps.googleusercontent.com',
      '1234-demo.apps.googleusercontent.com.example'
    ]) {
      expect(isGoogleOAuthClientId(invalid), isFalse);
    }
  });

  test('the Android OAuth ID comes from the build configuration', () {
    const id = '1234-cashu.apps.googleusercontent.com';
    expect(resolveGoogleAndroidClientId(' $id '), id);
    expect(resolveGoogleAndroidClientId(''), isNull);
    expect(resolveGoogleAndroidClientId('GOCSPX-example'), isNull);
    expect(resolveGoogleAndroidClientId(googleAndroidServerClientId),
        googleBrowserClientId);
  });
}
