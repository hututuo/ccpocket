import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/messages.dart';
import 'file_browser_service.dart';
import 'file_mutation_auth_host.dart';

enum _MutationAuthChoice { biometric, password }

typedef _PasswordApproval = ({String password, bool enrollBiometrics});

Future<FileMutationAuthorization?> requestFileMutationAuthorization(
  BuildContext context,
  FileMutationOperation operation,
) async {
  final service = context.read<FileBrowserService>();
  if (!service.uploadMutationAuthRequired) return null;
  if (!service.mutationAuthSupportedByBridge) {
    throw const FileBrowserException('mutation_auth_unsupported');
  }

  final copy = _FileMutationAuthCopy.of(context);
  final snapshot = await service.biometricHost.snapshot();
  final state = await service.mutationAuthState(
    deviceId: snapshot.supported ? snapshot.deviceId : null,
  );
  if (!context.mounted) return null;
  if (state.passwordConfigured != true) {
    await _showPasswordNotConfigured(context, copy);
    throw const FileBrowserException('password_not_configured');
  }

  final canUseBiometrics = state.biometricEnrolled == true && snapshot.canSign;
  if (canUseBiometrics) {
    final choice = await _chooseAuthorizationMethod(context, copy);
    if (!context.mounted || choice == null) return null;
    if (choice == _MutationAuthChoice.biometric) {
      try {
        final challenge = await service.mutationAuthChallenge(
          deviceId: snapshot.deviceId,
          operation: operation,
        );
        final signature = await service.biometricHost.sign(
          challenge.payload!,
          reason: copy.faceIdReason(operation.filename),
        );
        if (signature.deviceId != snapshot.deviceId) {
          throw const FileMutationBiometricException(
            'biometric_device_mismatch',
          );
        }
        return FileMutationBiometricAuthorization(
          challengeId: challenge.challengeId!,
          deviceId: signature.deviceId,
          signature: signature.signature,
        );
      } on FileMutationBiometricException catch (error) {
        if (error.code == 'biometric_cancelled') return null;
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(copy.faceIdFallback)));
        }
      } on FileBrowserException {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(copy.faceIdFallback)));
        }
      }
    }
  }

  if (!context.mounted) return null;
  final mayEnroll =
      snapshot.supported &&
      snapshot.canEvaluateBiometrics &&
      (!snapshot.keyPrepared || state.biometricEnrolled != true);
  final approval = await _requestPassword(
    context,
    copy,
    mayEnrollBiometrics: mayEnroll,
  );
  if (approval == null) return null;

  if (approval.enrollBiometrics) {
    try {
      final key = await service.biometricHost.prepareKey();
      await service.enrollMutationBiometrics(
        deviceId: key.deviceId,
        publicKey: key.publicKey,
        password: approval.password,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(copy.faceIdEnabled)));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(copy.faceIdEnrollmentFailed)));
      }
    }
  }
  return FileMutationPasswordAuthorization(approval.password);
}

Future<_MutationAuthChoice?> _chooseAuthorizationMethod(
  BuildContext context,
  _FileMutationAuthCopy copy,
) => showDialog<_MutationAuthChoice>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: Text(copy.approvalTitle),
    content: Text(copy.approvalBody),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: Text(copy.cancel),
      ),
      TextButton.icon(
        onPressed: () =>
            Navigator.of(dialogContext).pop(_MutationAuthChoice.password),
        icon: const Icon(Icons.password_outlined),
        label: Text(copy.usePassword),
      ),
      FilledButton.icon(
        onPressed: () =>
            Navigator.of(dialogContext).pop(_MutationAuthChoice.biometric),
        icon: const Icon(Icons.face_outlined),
        label: Text(copy.useFaceId),
      ),
    ],
  ),
);

Future<_PasswordApproval?> _requestPassword(
  BuildContext context,
  _FileMutationAuthCopy copy, {
  required bool mayEnrollBiometrics,
}) async {
  final controller = TextEditingController();
  var enrollBiometrics = mayEnrollBiometrics;
  try {
    return await showDialog<_PasswordApproval>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(copy.passwordTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(copy.passwordBody),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                maxLength: 256,
                decoration: InputDecoration(
                  labelText: copy.passwordLabel,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (controller.text.length >= 8) {
                    Navigator.of(dialogContext).pop((
                      password: controller.text,
                      enrollBiometrics: enrollBiometrics,
                    ));
                  }
                },
              ),
              if (mayEnrollBiometrics)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: enrollBiometrics,
                  onChanged: (value) =>
                      setState(() => enrollBiometrics = value ?? false),
                  title: Text(copy.enableFaceId),
                  subtitle: Text(copy.enableFaceIdBody),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(copy.cancel),
            ),
            FilledButton(
              onPressed: controller.text.length < 8
                  ? null
                  : () => Navigator.of(dialogContext).pop((
                      password: controller.text,
                      enrollBiometrics: enrollBiometrics,
                    )),
              child: Text(copy.approve),
            ),
          ],
        ),
      ),
    );
  } finally {
    controller.clear();
    controller.dispose();
  }
}

Future<void> _showPasswordNotConfigured(
  BuildContext context,
  _FileMutationAuthCopy copy,
) => showDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: Text(copy.passwordNotConfiguredTitle),
    content: Text(copy.passwordNotConfiguredBody),
    actions: [
      FilledButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: Text(copy.ok),
      ),
    ],
  ),
);

class _FileMutationAuthCopy {
  const _FileMutationAuthCopy(this.languageCode);

  factory _FileMutationAuthCopy.of(BuildContext context) =>
      _FileMutationAuthCopy(
        Localizations.localeOf(context).languageCode.toLowerCase(),
      );

  final String languageCode;

  bool get _zh => languageCode == 'zh';
  bool get _ja => languageCode == 'ja';
  bool get _ko => languageCode == 'ko';

  String get approvalTitle => _pick(
    zh: '确认修改 Mac 文件',
    ja: 'Mac ファイルの変更を確認',
    ko: 'Mac 파일 변경 확인',
    en: 'Approve Mac file change',
  );
  String get approvalBody => _pick(
    zh: '上传会在 Mac 上创建文件。请用 Face ID 或 Bridge 密码确认本次操作。',
    ja: 'アップロードにより Mac にファイルが作成されます。Face ID または Bridge パスワードで承認してください。',
    ko: '업로드하면 Mac에 파일이 생성됩니다. Face ID 또는 Bridge 암호로 승인하세요.',
    en: 'Uploading creates a file on your Mac. Approve this operation with Face ID or the Bridge password.',
  );
  String get useFaceId => _pick(
    zh: '使用 Face ID',
    ja: 'Face ID を使う',
    ko: 'Face ID 사용',
    en: 'Use Face ID',
  );
  String get usePassword =>
      _pick(zh: '输入密码', ja: 'パスワードを入力', ko: '암호 입력', en: 'Enter password');
  String get passwordTitle => _pick(
    zh: 'Bridge 修改密码',
    ja: 'Bridge 変更パスワード',
    ko: 'Bridge 변경 암호',
    en: 'Bridge change password',
  );
  String get passwordBody => _pick(
    zh: '密码只用于确认这一次操作，不会保存在手机上。',
    ja: 'パスワードは今回の承認だけに使われ、端末には保存されません。',
    ko: '암호는 이번 승인에만 사용되며 휴대폰에 저장되지 않습니다.',
    en: 'The password is used only for this approval and is never stored on the phone.',
  );
  String get passwordLabel =>
      _pick(zh: '密码', ja: 'パスワード', ko: '암호', en: 'Password');
  String get enableFaceId => _pick(
    zh: '以后允许使用 Face ID',
    ja: '今後 Face ID を使用する',
    ko: '앞으로 Face ID 사용',
    en: 'Enable Face ID for next time',
  );
  String get enableFaceIdBody => _pick(
    zh: '私钥只保存在这台 iPhone 的安全芯片中；Bridge 只保存公钥。',
    ja: '秘密鍵はこの iPhone の Secure Enclave にのみ保存され、Bridge は公開鍵だけを保持します。',
    ko: '개인 키는 이 iPhone의 Secure Enclave에만 저장되고 Bridge에는 공개 키만 저장됩니다.',
    en: 'The private key stays in this iPhone’s Secure Enclave; the Bridge stores only its public key.',
  );
  String get approve => _pick(zh: '允许', ja: '許可', ko: '허용', en: 'Approve');
  String get cancel => _pick(zh: '取消', ja: 'キャンセル', ko: '취소', en: 'Cancel');
  String get ok => _pick(zh: '知道了', ja: 'OK', ko: '확인', en: 'OK');
  String get faceIdFallback => _pick(
    zh: 'Face ID 未能完成确认，请改用 Bridge 密码',
    ja: 'Face ID で承認できませんでした。Bridge パスワードを使用してください',
    ko: 'Face ID 승인을 완료하지 못했습니다. Bridge 암호를 사용하세요',
    en: 'Face ID could not approve the change. Use the Bridge password instead.',
  );
  String get faceIdEnabled => _pick(
    zh: 'Face ID 已为这台 Bridge 启用',
    ja: 'この Bridge で Face ID を有効にしました',
    ko: '이 Bridge에 Face ID를 활성화했습니다',
    en: 'Face ID is now enabled for this Bridge',
  );
  String get faceIdEnrollmentFailed => _pick(
    zh: 'Face ID 设置未完成；本次仍将使用密码确认',
    ja: 'Face ID の設定に失敗しました。今回はパスワードで承認します',
    ko: 'Face ID 설정을 완료하지 못했습니다. 이번에는 암호로 승인합니다',
    en: 'Face ID setup did not finish; this operation will still use the password.',
  );
  String get passwordNotConfiguredTitle => _pick(
    zh: '先在 Mac 设置密码',
    ja: '先に Mac でパスワードを設定',
    ko: '먼저 Mac에서 암호 설정',
    en: 'Set a password on the Mac first',
  );
  String get passwordNotConfiguredBody => _pick(
    zh: '为了防止误改全盘文件，请先在 Bridge 的“文件访问”设置中配置修改密码，然后再重试。',
    ja: 'Mac 全体のファイルを誤って変更しないよう、Bridge の「ファイルアクセス」で変更パスワードを設定してから再試行してください。',
    ko: '전체 디스크 파일의 실수 변경을 막기 위해 Bridge의 파일 접근 설정에서 변경 암호를 먼저 설정하세요.',
    en: 'To prevent accidental full-disk changes, configure the change password in the Bridge file-access settings, then try again.',
  );

  String faceIdReason(String filename) => _pick(
    zh: '允许 CC Pocket 在 Mac 上创建“$filename”',
    ja: 'CC Pocket が Mac に「$filename」を作成することを許可',
    ko: 'CC Pocket이 Mac에 “$filename” 파일을 생성하도록 허용',
    en: 'Allow CC Pocket to create “$filename” on your Mac',
  );

  String _pick({
    required String zh,
    required String ja,
    required String ko,
    required String en,
  }) {
    if (_zh) return zh;
    if (_ja) return ja;
    if (_ko) return ko;
    return en;
  }
}
