import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:ccpocket/widgets/bubbles/error_bubble.dart';

Widget _wrapErrorBubble({required Widget child, required Locale locale}) {
  return MaterialApp(
    theme: AppTheme.darkTheme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: locale,
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('renders Codex warnings with a warning title', (tester) async {
    await tester.pumpWidget(
      _wrapErrorBubble(
        locale: const Locale('en'),
        child: const ErrorBubble(
          message: ErrorMessage(
            message: 'Check your Codex configuration.',
            errorCode: 'codex_warning',
          ),
        ),
      ),
    );

    expect(find.text('Codex Warning'), findsOneWidget);
    expect(find.text('Check your Codex configuration.'), findsOneWidget);
    expect(find.byKey(const ValueKey('codex_warning_dismiss')), findsNothing);
  });

  testWidgets('localizes shared Codex runtime errors with recovery guidance', (
    tester,
  ) async {
    const cases = {
      'codex_shared_runtime_writer_unavailable': {
        'en': (
          title: 'Conversation control is still synchronizing',
          hint:
              "Reconnect to the active Bridge and wait for this conversation's control state before retrying.",
        ),
        'zh': (
          title: '会话控制权仍在同步',
          hint: '请重新连接当前活动的 Bridge，等待此会话的控制状态同步完成后再重试。',
        ),
        'ja': (
          title: '会話の制御状態を同期しています',
          hint: 'アクティブな Bridge に再接続し、この会話の制御状態が同期されてから再試行してください。',
        ),
        'ko': (
          title: '대화 제어 상태를 동기화하는 중',
          hint: '활성 Bridge에 다시 연결하고 이 대화의 제어 상태가 동기화된 뒤 다시 시도하세요.',
        ),
      },
      'codex_action_broker_required': {
        'en': (
          title: 'Use the current approval request',
          hint:
              'Respond from the active approval card. Refresh the conversation if the card is not visible.',
        ),
        'zh': (title: '请使用当前审批请求', hint: '请在当前审批卡片中操作；如果卡片没有显示，请刷新会话。'),
        'ja': (
          title: '現在の承認リクエストを使用してください',
          hint: '現在の承認カードから応答してください。カードが表示されない場合は会話を更新してください。',
        ),
        'ko': (
          title: '현재 승인 요청을 사용하세요',
          hint: '현재 승인 카드에서 응답하세요. 카드가 보이지 않으면 대화를 새로 고치세요.',
        ),
      },
    };

    for (final entry in cases.entries) {
      for (final localeEntry in entry.value.entries) {
        final locale = Locale(localeEntry.key);
        final expected = localeEntry.value;
        await tester.pumpWidget(
          _wrapErrorBubble(
            locale: locale,
            child: ErrorBubble(
              message: ErrorMessage(
                message: 'The shared Codex runtime cannot accept this action.',
                errorCode: entry.key,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text(expected.title), findsOneWidget);
        expect(find.text(expected.hint), findsOneWidget);
      }
    }
  });

  testWidgets('dismisses a Codex warning from its close button', (
    tester,
  ) async {
    var dismissed = false;
    await tester.pumpWidget(
      _wrapErrorBubble(
        locale: const Locale('en'),
        child: ErrorBubble(
          message: const ErrorMessage(
            message: 'thread/rollback is deprecated',
            errorCode: 'codex_warning',
          ),
          onDismiss: () => dismissed = true,
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('codex_warning_dismiss')));

    expect(dismissed, isTrue);
  });

  group('ErrorBubble auth UI', () {
    testWidgets('shows API key guidance for auth_api_error', (tester) async {
      const message = ErrorMessage(
        message: 'Failed to authenticate. API Error: 401 terminated',
        errorCode: 'auth_api_error',
      );

      await tester.pumpWidget(
        _wrapErrorBubble(
          locale: const Locale('ja'),
          child: const ErrorBubble(message: message),
        ),
      );

      expect(find.text('APIキーが必要です'), findsOneWidget);
      expect(
        find.text(
          'Anthropic の現行 Claude Agent SDK ドキュメントでは、'
          'サードパーティ製品で Claude のサブスクリプションログインを'
          '使うことは許可されていません。APIキーをご利用ください。',
        ),
        findsOneWidget,
      );
      expect(find.text('APIキーの取得:'), findsOneWidget);
      expect(find.text('ANTHROPIC_API_KEY=sk-ant-...'), findsOneWidget);
      expect(find.text('console.anthropic.com/settings/keys'), findsOneWidget);
      expect(find.text('手順を見る'), findsNothing);
      expect(find.text('claude'), findsNothing);
      expect(find.text('/login'), findsNothing);
    });

    testWidgets('keeps non-auth error layout unchanged', (tester) async {
      const message = ErrorMessage(
        message: 'Project path not allowed',
        errorCode: 'path_not_allowed',
      );

      await tester.pumpWidget(
        _wrapErrorBubble(
          locale: const Locale('en'),
          child: const ErrorBubble(message: message),
        ),
      );

      expect(find.text('Path Not Allowed'), findsOneWidget);
      expect(find.text('Project path not allowed'), findsOneWidget);
      expect(find.text('View steps'), findsNothing);
    });

    testWidgets('localizes structured path errors without rewriting details', (
      tester,
    ) async {
      const message = ErrorMessage(
        message: '/Volumes/Research is outside the configured roots',
        errorCode: 'path_not_allowed',
      );

      await tester.pumpWidget(
        _wrapErrorBubble(
          locale: const Locale('zh'),
          child: const ErrorBubble(message: message),
        ),
      );

      expect(find.text('路径不在允许范围内'), findsOneWidget);
      expect(
        find.text('/Volumes/Research is outside the configured roots'),
        findsOneWidget,
      );
      expect(find.text('请更新 Bridge 服务端的 BRIDGE_ALLOWED_DIRS'), findsOneWidget);
      expect(find.text('Path Not Allowed'), findsNothing);
    });

    testWidgets('shows Codex CLI install guidance', (tester) async {
      const message = ErrorMessage(
        message:
            'Codex CLI is not installed or not available on PATH on the Bridge machine.',
        errorCode: 'codex_cli_not_found',
      );

      await tester.pumpWidget(
        _wrapErrorBubble(
          locale: const Locale('en'),
          child: const ErrorBubble(message: message),
        ),
      );

      expect(find.text('Codex CLI Not Installed'), findsOneWidget);
      expect(
        find.text(
          'Install Codex CLI on the Bridge machine, then restart Bridge',
        ),
        findsOneWidget,
      );
    });

    testWidgets('does not show Claude login card for GitHub CLI auth text', (
      tester,
    ) async {
      const message = ErrorMessage(
        message:
            'You are not logged into any GitHub hosts. To log in, run: gh auth login',
      );

      await tester.pumpWidget(
        _wrapErrorBubble(
          locale: const Locale('en'),
          child: const ErrorBubble(message: message),
        ),
      );

      expect(find.text('Claude login required'), findsNothing);
      expect(find.text('claude'), findsNothing);
      expect(find.text('/login'), findsNothing);
      expect(find.textContaining('gh auth login'), findsOneWidget);
    });
  });
}
