import 'package:budget/struct/googleServiceConfiguration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default Google authorization only requests the backup scope', () {
    expect(requestedGoogleScopes(), [
      'https://www.googleapis.com/auth/drive.appdata',
    ]);
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

  test('Android OAuth uses a valid build ID or a locally configured public ID',
      () {
    const built = '1234-built.apps.googleusercontent.com';
    const saved = '1234-preview.apps.googleusercontent.com';
    expect(resolveGoogleAndroidClientId(buildId: built, savedId: saved), built);
    expect(
        resolveGoogleAndroidClientId(buildId: '', savedId: ' $saved '), saved);
    expect(resolveGoogleAndroidClientId(buildId: '', savedId: 'GOCSPX-example'),
        isNull);
    expect(resolveGoogleAndroidClientId(buildId: ''), isNull);
  });
}
