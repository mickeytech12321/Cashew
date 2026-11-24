import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis/gmail/v1.dart' as gmail;

const googleAndroidServerClientId =
    String.fromEnvironment('CASHEW_GOOGLE_WEB_CLIENT_ID');

const googleBackupScopes = <String>[drive.DriveApi.driveAppdataScope];
const googleAttachmentScopes = <String>[drive.DriveApi.driveFileScope];
const googleMailScopes = <String>[gmail.GmailApi.gmailModifyScope];

bool isGoogleOAuthClientId(String value) =>
    RegExp(r'^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$').hasMatch(value);

List<String> requestedGoogleScopes({
  bool attachments = false,
  bool mail = false,
}) =>
    [
      ...googleBackupScopes,
      if (attachments) ...googleAttachmentScopes,
      if (mail) ...googleMailScopes,
    ];
