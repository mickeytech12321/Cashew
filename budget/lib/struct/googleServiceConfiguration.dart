import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis/gmail/v1.dart' as gmail;

const _cashuGoogleWebClientId =
    '849549168028-qa71qphgon3u7fdh9ij78kqsvnk4i3j9.apps.googleusercontent.com';
const _configuredGoogleWebClientId =
    String.fromEnvironment('CASHEW_GOOGLE_WEB_CLIENT_ID');
const googleBrowserClientId = _configuredGoogleWebClientId == ''
    ? _cashuGoogleWebClientId
    : _configuredGoogleWebClientId;
const googleAndroidServerClientId = googleBrowserClientId;

const googleBackupScopes = <String>[drive.DriveApi.driveAppdataScope];
const googleAttachmentScopes = <String>[drive.DriveApi.driveFileScope];
const googleMailScopes = <String>[gmail.GmailApi.gmailModifyScope];

bool isGoogleOAuthClientId(String value) =>
    RegExp(r'^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$').hasMatch(value);

String? resolveGoogleAndroidClientId(String buildId) {
  final compiled = buildId.trim();
  return isGoogleOAuthClientId(compiled) ? compiled : null;
}

List<String> requestedGoogleScopes({
  bool backup = true,
  bool attachments = false,
  bool mail = false,
}) =>
    [
      if (backup) ...googleBackupScopes,
      if (attachments) ...googleAttachmentScopes,
      if (mail) ...googleMailScopes,
    ];
