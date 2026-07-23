/// ccpocket - Claude Code Mobile Client
///
/// This is the main entry point for the ccpocket Flutter application.
///
/// Key responsibilities:
/// - Initializes Marionette binding for E2E testing in debug mode
/// - Sets up global error handling
/// - Initializes core services (BridgeService, DatabaseService, NotificationService, etc.)
/// - Configures repository and Bloc providers for state management
/// - Handles deep links for connection URLs and session navigation
///
/// Note: This file has been verified for Plan Mode workflow testing.
library;

import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:marionette_flutter/marionette_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talker_bloc_logger/talker_bloc_logger.dart';

import 'core/logger.dart';
import 'l10n/app_localizations.dart';
import 'features/auto_approval/auto_approval_service.dart';
import 'features/background_sync/background_sync_coordinator.dart';
import 'features/background_sync/background_sync_host.dart';
import 'features/conversation_mirror/conversation_mirror_service.dart';
import 'features/conversation_mirror/storage/conversation_mirror_storage.dart';
import 'features/file_browser/file_browser_service.dart';
import 'features/file_transfer/file_transfer_service.dart';
import 'features/file_transfer/file_transfer_sheet.dart';
import 'features/file_transfer/file_transfer_storage.dart';
import 'features/file_transfer/ios_file_transfer_gateway.dart';
import 'features/mobile_host/mobile_host_service.dart';
import 'features/mobile_update/mobile_update_restart_prompt.dart';
import 'features/mobile_update/mobile_update_service.dart';
import 'features/session_list/state/session_list_cubit.dart';
import 'features/git/state/git_status_cubit.dart';
import 'features/git/state/git_view_cache_service.dart';
import 'features/settings/state/settings_cubit.dart';
import 'features/settings/state/settings_state.dart';
import 'models/code_font_family.dart';
import 'models/messages.dart';
import 'providers/bridge_cubits.dart';
import 'providers/machine_manager_cubit.dart';
import 'providers/server_discovery_cubit.dart';
import 'router/app_router.dart';
import 'router/session_route_observer.dart';
import 'services/app_icon_service.dart';
import 'services/bridge_service.dart';
import 'services/connection_url_parser.dart';
import 'services/database_service.dart';
import 'services/draft_service.dart';
import 'services/fcm_service.dart';
import 'services/in_app_review_service.dart';
import 'services/machine_manager_service.dart';
import 'services/mock_preview_extension.dart';
import 'services/notification_service.dart';
import 'services/performance_probe_extension.dart';
import 'services/prompt_history_service.dart';
import 'services/revenuecat_service.dart';
import 'services/ssh_bridge_tunnel_service.dart';
import 'services/ssh_startup_service.dart';
import 'services/support_banner_service.dart';
import 'theme/app_theme.dart';
import 'services/store_screenshot_extension.dart';
import 'theme/markdown_style.dart';
import 'utils/platform_helper.dart';
import 'widgets/release_error_widget.dart';

/// Top-level handler for FCM background messages.
/// Required by firebase_messaging to process messages when app is in background.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // No-op: FCM notification messages are automatically displayed by the OS.
  // This handler is registered to prevent the "no onBackgroundMessage handler"
  // warning on Android.
}

Future<void> _initializeFileTransferAfterFirstFrame(
  FileTransferService service,
) async {
  try {
    await service.initialize();
  } catch (error) {
    logger.error('[main] FileTransferService init failed', error);
  }
}

void main() async {
  if (kDebugMode && !kIsWeb) {
    MarionetteBinding.ensureInitialized();
    registerStoreScreenshotExtensions();
    registerMockPreviewExtensions();
    registerPerformanceProbeExtensions();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }
  Bloc.observer = TalkerBlocObserver(talker: logger);

  FlutterError.onError = (details) {
    logger.error(
      '[FlutterError] ${details.exceptionAsString()}',
      details.exception,
      details.stack,
    );
  };
  installReleaseErrorWidget();
  // Initialize notifications eagerly so the Android notification channel is
  // created before any FCM message arrives. Without this, FCM falls back to
  // the low-importance fcm_fallback_notification_channel and notifications
  // appear only in the history drawer instead of as heads-up popups.
  try {
    await NotificationService.instance.init();
  } catch (e) {
    logger.error('[main] NotificationService init failed', e);
  }
  // Initialize SharedPreferences and services
  final prefs = await SharedPreferences.getInstance();
  const secureStorage = FlutterSecureStorage();
  const mobileUpdateSecureStorage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accountName: 'ccpocket_mobile_update_v1',
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
  );
  final mobileHostService = MobileHostService();
  final mobileHostSnapshot = !kIsWeb && isMobilePlatform
      ? await mobileHostService.loadSnapshot()
      : const MobileHostSnapshot.unavailable('mobile_host_not_applicable');
  final mobileUpdateService = MobileUpdateService(
    preferences: prefs,
    secureStore: const FlutterMobileUpdateSecureStore(
      mobileUpdateSecureStorage,
    ),
  );
  await mobileUpdateService.initialize();
  final machineManagerService = MachineManagerService(prefs, secureStorage);
  // SSH is only supported on native platforms (not web)
  final sshStartupService = kIsWeb
      ? null
      : SshStartupService(machineManagerService);
  final sshBridgeTunnelService = kIsWeb
      ? null
      : SshBridgeTunnelService(machineManagerService);
  if (sshBridgeTunnelService != null) {
    machineManagerService.configureBridgeTunnelResolvers(
      wsUrlResolver: sshBridgeTunnelService.buildWsUrl,
      httpBaseUrlResolver: sshBridgeTunnelService.buildHttpBaseUrl,
    );
  }

  const fileTransferSecureStorage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accountName: 'ccpocket_file_transfer_v2',
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
  );
  final FileTransferPlatformGateway fileTransferPlatform = isIOSPlatform
      ? const IosFileTransferGateway()
      : const UnsupportedFileTransferGateway();
  final fileTransferPlatformSupport = await fileTransferPlatform.probeSupport();
  if (isIOSPlatform && !fileTransferPlatformSupport.supported) {
    logger.warning(
      '[main] File transfer native capability disabled: '
      '${fileTransferPlatformSupport.reason}',
    );
  }
  final bridge = BridgeService(
    fileTransferClientSupported: fileTransferPlatformSupport.supported,
    clientAppVersion:
        mobileHostSnapshot.baseVersion ??
        fileTransferPlatformSupport.appVersion,
    clientMobileRuntime: mobileHostSnapshot.toClientCapabilitiesJson(
      patchNumber: mobileUpdateService.state.currentPatchNumber,
    ),
  );
  bridge.onDisconnect = sshBridgeTunnelService?.closeAll;
  final fileTransferService = FileTransferService(
    bridge: BridgeServiceFileTransferGateway(bridge),
    storage: FileTransferStorage(
      applicationSupportDirectory: getApplicationSupportDirectory,
      downloadsDirectory: defaultFileTransferDownloadsDirectory,
      secretStore: const FlutterSecureFileTransferSecretStore(
        fileTransferSecureStorage,
      ),
    ),
    picker: fileTransferPlatform,
    capacity: fileTransferPlatform,
    commit: fileTransferPlatform,
    platformSupported: fileTransferPlatformSupport.supported,
    receivedFileExportSupported:
        (fileTransferPlatformSupport.nativeApiVersion ?? 0) >=
        receivedFileExportNativeApiVersion,
    notifications: NotificationServiceFileTransferGateway(
      NotificationService.instance,
    ),
    preferences: prefs,
  );
  final fileBrowserService = FileBrowserService(
    bridge: BridgeServiceFileBrowserGateway(bridge),
    preferences: prefs,
    fileTransferClientSupported: fileTransferPlatformSupport.supported,
  );
  final autoApprovalService = AutoApprovalService(
    bridge: bridge,
    preferences: prefs,
  )..initialize();
  final conversationMirrorDatabase = ConversationMirrorDatabase();
  final conversationMirrorService = ConversationMirrorService(
    bridge: bridge,
    store: ConversationMirrorStore(conversationMirrorDatabase),
    database: conversationMirrorDatabase,
  );
  unawaited(conversationMirrorService.initialize());
  final backgroundSyncHost = MethodChannelBackgroundSyncHost(
    supportsContinuation: mobileHostSnapshot.supports(
      MobileHostCapability.backgroundContinuation,
    ),
    supportsAppRefresh: mobileHostSnapshot.supports(
      MobileHostCapability.backgroundRefreshWarmRuntime,
    ),
  );
  final backgroundSyncCoordinator = MobileBackgroundSyncCoordinator(
    host: backgroundSyncHost,
    bridge: BridgeServiceBackgroundSyncGateway(
      bridge,
      rebuildConnection: () async {
        final logicalIdentity = bridge.logicalConnectionIdentity;
        final machineId = machineIdFromLogicalConnectionIdentity(
          logicalIdentity,
        );
        if (machineId == null) return false;
        try {
          final url = await machineManagerService.buildWsUrl(machineId);
          if (bridge.logicalConnectionIdentity != logicalIdentity) return false;
          bridge.connect(url, logicalConnectionIdentity: logicalIdentity);
          return true;
        } catch (error) {
          logger.warning(
            '[background-sync] failed to rebuild the Bridge route: $error',
          );
          return false;
        }
      },
    ),
    mirror: ConversationMirrorBackgroundSyncGateway(conversationMirrorService),
  )..start(initialLifecycleState: WidgetsBinding.instance.lifecycleState);
  final fcmService = FcmService();
  final draftService = DraftService(prefs);
  final inAppReviewService = InAppReviewService(prefs: prefs);
  await inAppReviewService.attachToBridge(bridge);
  final supportBannerService = SupportBannerService(
    prefs: prefs,
    reviewService: inAppReviewService,
  );
  StoreScreenshotState.draftService = draftService;
  final dbService = DatabaseService();
  final promptHistoryService = PromptHistoryService(dbService);
  final promptHistorySyncSub = bridge.connectionStatus.listen((state) {
    if (state == BridgeConnectionState.connected) {
      unawaited(
        promptHistoryService.syncAll(
          machineManager: machineManagerService,
          bridgeService: bridge,
        ),
      );
    }
  });
  final appIconService = AppIconService();
  final revenueCatService = RevenueCatService();
  final settingsCubit = SettingsCubit(
    prefs,
    bridgeService: bridge,
    machineManager: machineManagerService,
    fcmService: fcmService,
    revenueCatService: revenueCatService,
    appIconService: appIconService,
  );
  final gitStatusCubit = GitStatusCubit(
    bridge: bridge,
    remoteStatusBadgeEnabled: () =>
        settingsCubit.state.showRemoteGitStatusBadge,
  );
  final gitViewCacheService = GitViewCacheService(
    bridge: bridge,
    gitStatusCubit: gitStatusCubit,
  );
  unawaited(revenueCatService.initialize());
  if (!kIsWeb && isMobilePlatform) {
    unawaited(mobileUpdateService.runStartupPolicy());
  }
  runApp(
    MultiRepositoryProvider(
      providers: [
        RepositoryProvider.value(value: logger),
        RepositoryProvider<BridgeService>(
          create: (_) => bridge,
          lazy: false,
          dispose: (service) {
            unawaited(promptHistorySyncSub.cancel());
            service.dispose();
          },
        ),
        ChangeNotifierProvider<AutoApprovalService>(
          create: (_) => autoApprovalService,
          lazy: false,
        ),
        ChangeNotifierProvider<FileTransferService>(
          create: (_) => fileTransferService,
          lazy: false,
        ),
        ChangeNotifierProvider<FileBrowserService>(
          create: (_) => fileBrowserService,
          lazy: false,
        ),
        ChangeNotifierProvider<ConversationMirrorService>(
          create: (_) => conversationMirrorService,
          lazy: false,
        ),
        RepositoryProvider<MobileHostService>.value(value: mobileHostService),
        ChangeNotifierProvider<MobileUpdateService>.value(
          value: mobileUpdateService,
        ),
        RepositoryProvider<GitViewCacheService>(
          create: (_) => gitViewCacheService,
          lazy: false,
          dispose: (service) => unawaited(service.dispose()),
        ),
        RepositoryProvider<DatabaseService>(
          create: (_) => dbService,
          lazy: false,
          dispose: (service) => unawaited(service.close()),
        ),
        RepositoryProvider<DraftService>.value(value: draftService),
        RepositoryProvider<InAppReviewService>(
          create: (_) => inAppReviewService,
          lazy: false,
          dispose: (service) => service.dispose(),
        ),
        ChangeNotifierProvider<SupportBannerService>(
          create: (_) => supportBannerService,
          lazy: false,
        ),
        RepositoryProvider<PromptHistoryService>.value(
          value: promptHistoryService,
        ),
        RepositoryProvider<AppIconService>.value(value: appIconService),
        RepositoryProvider<RevenueCatService>(
          create: (_) => revenueCatService,
          lazy: false,
          dispose: (service) => unawaited(service.dispose()),
        ),
        RepositoryProvider<MachineManagerService>(
          create: (_) => machineManagerService,
          lazy: false,
          dispose: (service) => service.dispose(),
        ),
        if (sshStartupService != null)
          RepositoryProvider<SshStartupService>.value(value: sshStartupService),
        if (sshBridgeTunnelService != null)
          RepositoryProvider<SshBridgeTunnelService>(
            create: (_) => sshBridgeTunnelService,
            lazy: false,
            dispose: (service) => unawaited(service.closeAll()),
          ),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider(
            create: (_) => ConnectionCubit(
              BridgeConnectionState.disconnected,
              bridge.connectionStatus,
            ),
          ),
          BlocProvider<GitStatusCubit>(
            create: (_) => gitStatusCubit,
            lazy: false,
          ),
          BlocProvider(
            create: (_) => ActiveSessionsCubit(const [], bridge.sessionList),
          ),
          BlocProvider(
            create: (_) =>
                RecentSessionsCubit(const [], bridge.recentSessionsStream),
          ),
          BlocProvider(
            create: (_) => GalleryCubit(const [], bridge.galleryStream),
          ),
          BlocProvider(create: (_) => FileListCubit(const [], bridge.fileList)),
          BlocProvider(
            create: (_) =>
                ProjectHistoryCubit(const [], bridge.projectHistoryStream),
          ),
          BlocProvider(create: (_) => ServerDiscoveryCubit()),
          BlocProvider(
            create: (ctx) =>
                SessionListCubit(bridge: ctx.read<BridgeService>()),
          ),
          BlocProvider(
            create: (_) => MachineManagerCubit(
              machineManagerService,
              sshStartupService,
              refreshLatestBridgeVersionOnInit: true,
            ),
          ),
          BlocProvider<SettingsCubit>(
            create: (_) => settingsCubit,
            lazy: false,
          ),
        ],
        child: CcpocketApp(
          fcmService: fcmService,
          mobileUpdateService: mobileUpdateService,
          backgroundSyncCoordinator: backgroundSyncCoordinator,
        ),
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_initializeFileTransferAfterFirstFrame(fileTransferService));
  });
}

class CcpocketApp extends StatefulWidget {
  const CcpocketApp({
    required this.fcmService,
    this.mobileUpdateService,
    this.backgroundSyncCoordinator,
    super.key,
  });

  final FcmService fcmService;
  final MobileUpdateService? mobileUpdateService;
  final MobileBackgroundSyncCoordinator? backgroundSyncCoordinator;

  @override
  State<CcpocketApp> createState() => _CcpocketAppState();
}

typedef _AppPresentationSettings = ({
  ThemeMode themeMode,
  String appLocaleId,
  double textScale,
  double codeFontSize,
  CodeFontFamily codeFontFamily,
});

class _CcpocketAppState extends State<CcpocketApp> {
  AppLinks? _appLinks;
  final _deepLinkNotifier = ValueNotifier<ConnectionParams?>(null);
  StreamSubscription<Uri>? _linkSub;
  StreamSubscription<RemoteMessage>? _fcmOnMessageSub;
  StreamSubscription<RemoteMessage>? _fcmOnMessageOpenedAppSub;

  late final AppRouter _appRouter;
  bool _routerInitialized = false;
  bool _fcmHandlersInitialized = false;
  bool _checkedInitialFcmSettings = false;
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    NotificationService.instance.configure(
      context.read<SettingsCubit>().state.notificationPreferences,
    );

    // Clear stale notifications on launch and whenever the app is resumed.
    _lifecycleListener = AppLifecycleListener(
      onStateChange: (state) {
        final backgroundSyncCoordinator = widget.backgroundSyncCoordinator;
        if (backgroundSyncCoordinator != null) {
          unawaited(backgroundSyncCoordinator.handleLifecycleState(state));
        }
        if (state == AppLifecycleState.resumed) {
          NotificationService.instance.cancelAll();
          final updateService = widget.mobileUpdateService;
          if (updateService != null) {
            unawaited(updateService.checkInBackground());
          }
        }
      },
    );
    final currentLifecycleState = WidgetsBinding.instance.lifecycleState;
    final backgroundSyncCoordinator = widget.backgroundSyncCoordinator;
    if (currentLifecycleState != null && backgroundSyncCoordinator != null) {
      unawaited(
        backgroundSyncCoordinator.handleLifecycleState(currentLifecycleState),
      );
    }
    NotificationService.instance.cancelAll();

    if (!kIsWeb) {
      _appLinks = AppLinks();
      _initDeepLinks();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_initializeMarkdownHighlighting());
    });
  }

  Future<void> _initializeMarkdownHighlighting() async {
    try {
      await initializeMarkdownSyntaxHighlight();
      // A deep link can open a code-bearing conversation on the first frame.
      // Rebuild once after the deferred highlighters are ready so that initial
      // plain-text fallback blocks gain syntax highlighting.
      if (mounted) setState(() {});
    } catch (error) {
      logger.error('[main] syntax_highlight init failed', error);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_checkedInitialFcmSettings) return;
    _checkedInitialFcmSettings = true;
    final settings = context.read<SettingsCubit>().state;
    if (settings.fcmEnabledMachines.isNotEmpty && settings.fcmAvailable) {
      _initFcmHandlers();
    }
  }

  void _initRouter() {
    if (_routerInitialized) return;
    _routerInitialized = true;
    _appRouter = AppRouter();
    StoreScreenshotState.navigatorKey = _appRouter.navigatorKey;
    // Navigate to session screen when user taps a notification
    NotificationService.instance.onNotificationTap = (payload) {
      _openSessionFromPayload(payload);
    };
  }

  void _initFcmHandlers() {
    if (kIsWeb || _fcmHandlersInitialized || !widget.fcmService.isAvailable) {
      return;
    }
    _fcmHandlersInitialized = true;

    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    _fcmOnMessageSub = FirebaseMessaging.onMessage.listen((message) {
      _handleForegroundFcmMessage(message);
    });
    _fcmOnMessageOpenedAppSub = FirebaseMessaging.onMessageOpenedApp.listen((
      message,
    ) {
      _openSessionFromData(message.data);
    });

    FirebaseMessaging.instance
        .getInitialMessage()
        .then((message) {
          if (message != null) {
            _openSessionFromData(message.data);
          }
        })
        .catchError((e) {
          logger.error('[fcm] getInitialMessage failed', e);
        });
  }

  Future<void> _handleForegroundFcmMessage(RemoteMessage message) async {
    final data = Map<String, dynamic>.from(message.data);
    final sessionId = data['sessionId']?.toString();
    final provider = _normalizeProvider(data['provider']?.toString());
    if (sessionId == null || sessionId.isEmpty) return;
    if (NotificationService.instance.isActiveSession(
      sessionId: sessionId,
      provider: provider,
    )) {
      return;
    }

    final notification = message.notification;
    final title =
        notification?.title ?? data['title']?.toString() ?? 'CC Pocket';
    final body =
        notification?.body ??
        data['body']?.toString() ??
        'New update available';
    final eventType = data['eventType']?.toString() ?? '';
    if (!NotificationService.instance.allowsRemoteEvent(
      eventType,
      appIsForeground: true,
    )) {
      return;
    }
    final payload = jsonEncode({'sessionId': sessionId, 'provider': provider});

    await NotificationService.instance.show(
      title: title,
      body: body,
      payload: payload,
      id: _notificationId(sessionId, provider, eventType),
    );
  }

  void _openSessionFromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return;
    if (payload == fileTransferNotificationPayload) {
      _openFileTransferInbox();
      return;
    }
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        _openSessionFromData(decoded);
        return;
      }
    } catch (_) {
      // Backward compatibility: payload may be plain sessionId text.
    }
    _openSessionFromData({'sessionId': payload, 'provider': 'claude'});
  }

  void _openFileTransferInbox() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = _appRouter.navigatorKey.currentContext;
      if (context != null) unawaited(showFileTransferSheet(context));
    });
  }

  void _openSessionFromData(Map<String, dynamic> data) {
    final sessionId = data['sessionId']?.toString();
    if (sessionId == null || sessionId.isEmpty) return;
    final provider = _normalizeProvider(data['provider']?.toString());
    if (provider == 'codex') {
      _appRouter.navigate(CodexSessionRoute(sessionId: sessionId));
      return;
    }
    _appRouter.navigate(ClaudeSessionRoute(sessionId: sessionId));
  }

  String _normalizeProvider(String? provider) {
    return provider == 'codex' ? 'codex' : 'claude';
  }

  int _notificationId(String sessionId, String provider, String eventType) {
    final raw = '$provider:$sessionId:$eventType';
    var hash = 0;
    for (final code in raw.codeUnits) {
      hash = ((hash * 31) + code) & 0x7fffffff;
    }
    return hash;
  }

  Future<void> _initDeepLinks() async {
    // Handle cold start
    try {
      final initialUri = await _appLinks!.getInitialLink().timeout(
        const Duration(seconds: 3),
        onTimeout: () => null,
      );
      if (initialUri != null) {
        _handleUri(initialUri);
      }
    } catch (e) {
      logger.error('[deep_link] getInitialLink failed', e);
    }

    // Handle warm start / incoming links while running
    try {
      _linkSub = _appLinks!.uriLinkStream.listen(
        _handleUri,
        onError: (e) => logger.error('[deep_link] stream error', e),
      );
    } catch (e) {
      logger.error('[deep_link] uriLinkStream failed', e);
    }
  }

  void _handleUri(Uri uri) {
    final params = ConnectionUrlParser.parse(uri.toString());
    if (params == null) return;

    switch (params) {
      case ConnectionParams():
        _deepLinkNotifier.value = params;
      case SessionLinkParams(:final sessionId):
        _appRouter.push(ClaudeSessionRoute(sessionId: sessionId));
    }
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    final backgroundSyncCoordinator = widget.backgroundSyncCoordinator;
    if (backgroundSyncCoordinator != null) {
      unawaited(backgroundSyncCoordinator.dispose());
    }
    _linkSub?.cancel();
    _fcmOnMessageSub?.cancel();
    _fcmOnMessageOpenedAppSub?.cancel();
    _deepLinkNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Initialize router on first build (needs BlocProvider context)
    _initRouter();

    return BlocListener<SettingsCubit, SettingsState>(
      listenWhen: (previous, current) =>
          previous.fcmAvailable != current.fcmAvailable ||
          previous.fcmEnabledMachines.isEmpty !=
              current.fcmEnabledMachines.isEmpty ||
          previous.notificationPreferences != current.notificationPreferences,
      listener: (context, settings) {
        NotificationService.instance.configure(
          settings.notificationPreferences,
        );
        if (settings.fcmEnabledMachines.isNotEmpty && settings.fcmAvailable) {
          _initFcmHandlers();
        }
      },
      child:
          BlocSelector<SettingsCubit, SettingsState, _AppPresentationSettings>(
            selector: (settings) => (
              themeMode: settings.themeMode,
              appLocaleId: settings.appLocaleId,
              textScale: settings.textScale,
              codeFontSize: settings.codeFontSize,
              codeFontFamily: settings.codeFontFamily,
            ),
            builder: (context, settings) {
              final appLocale = settings.appLocaleId.isEmpty
                  ? null
                  : Locale(settings.appLocaleId);
              final themeLocale =
                  appLocale ??
                  WidgetsBinding.instance.platformDispatcher.locale;
              updateReleaseErrorWidgetLocale(appLocale);
              return MaterialApp.router(
                title: 'CC Pocket',
                theme: AppTheme.lightThemeForLocale(themeLocale),
                darkTheme: AppTheme.darkThemeForLocale(themeLocale),
                themeMode: settings.themeMode,
                locale: appLocale,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                routerConfig: _appRouter.config(
                  navigatorObservers: () => [SessionRouteObserver()],
                ),
                builder: (context, child) {
                  final mediaQuery = MediaQuery.maybeOf(context);
                  final app = child ?? const SizedBox.shrink();
                  if (mediaQuery == null) return app;
                  return MediaQuery(
                    data: mediaQuery.copyWith(
                      textScaler: _AppTextScaler(
                        base: mediaQuery.textScaler,
                        multiplier: settings.textScale,
                      ),
                    ),
                    child: widget.mobileUpdateService == null
                        ? app
                        : MobileUpdateRestartPrompt(
                            service: widget.mobileUpdateService!,
                            child: app,
                          ),
                  );
                },
                debugShowCheckedModeBanner: false,
              );
            },
          ),
    );
  }
}

class _AppTextScaler extends TextScaler {
  const _AppTextScaler({required this.base, required this.multiplier});

  final TextScaler base;
  final double multiplier;

  @override
  double scale(double fontSize) => base.scale(fontSize) * multiplier;

  @override
  // Required by TextScaler for legacy callers.
  // ignore: deprecated_member_use
  double get textScaleFactor => base.textScaleFactor * multiplier;

  @override
  bool operator ==(Object other) {
    return other is _AppTextScaler &&
        other.base == base &&
        other.multiplier == multiplier;
  }

  @override
  int get hashCode => Object.hash(base, multiplier);
}
