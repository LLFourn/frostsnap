import 'dart:async';
import 'dart:io';

import 'package:confetti/confetti.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:frostsnap/contexts.dart';
import 'package:frostsnap/copy_feedback.dart';
import 'package:frostsnap/global.dart';
import 'package:frostsnap/secure_key_provider.dart';
import 'package:frostsnap/serialport.dart';
import 'package:frostsnap/snackbar.dart';
import 'package:frostsnap/settings.dart';
import 'package:frostsnap/sim_device_tray.dart';
import 'package:frostsnap/stream_ext.dart';
import 'package:frostsnap/theme.dart';
import 'package:frostsnap/wallet.dart';
import 'package:frostsnap/wallet_list_controller.dart';
import 'package:frostsnap/src/rust/api.dart';
import 'package:frostsnap/src/rust/api/bitcoin.dart';
import 'package:frostsnap/src/rust/api/device_list.dart';
import 'package:frostsnap/src/rust/api/init.dart';
import 'package:frostsnap/src/rust/api/settings.dart';
import 'package:frostsnap/src/rust/api/log.dart';
import 'package:frostsnap/src/rust/frb_generated.dart';

Future<void> main() async {
  // enable this if you're trying to figure out why things are displaying in
  // certain positions/sizes
  debugPaintSizeEnabled = false;
  // dunno what this is but for some reason it's needed 🤦
  // https://stackoverflow.com/questions/57689492/flutter-unhandled-exception-servicesbinding-defaultbinarymessenger-was-accesse
  WidgetsFlutterBinding.ensureInitialized();

  // 💡 renable if you want to mess around with different fonts
  GoogleFonts.config.allowRuntimeFetching = false;
  // 🖕 to all intellectual property but I am doing what I am told.
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString('assets/google_fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(['google_fonts'], license);
  });

  await RustLib.init();
  api = Api();

  String? startupError;
  // // set logging up first before doing anything else
  final Stream<String> logStream = api
      .turnLoggingOn(level: LogLevel.debug)
      .toReplaySubject();

  // // wait for first message to appear so that logging is working before we carry on
  await logStream.first;
  AppCtx? appCtx;

  try {
    final appDir = await getApplicationSupportDirectory();
    final appDirPath = appDir.path;
    if (kSim) {
      // Point the sim at a disposable app dir (clean DB per run, and the device
      // channel's socket lives here too) via `--dart-define=SIM_APP_DIR=/tmp/...`;
      // defaults to the app-support dir.
      const simAppDir = String.fromEnvironment('SIM_APP_DIR');
      const simDeviceCount = int.fromEnvironment(
        'SIM_DEVICE_COUNT',
        defaultValue: 1,
      );
      final (coord_, appCtx_, pool_) = await api.loadSim(
        appDir: simAppDir.isEmpty ? appDirPath : simAppDir,
        seed: 1,
        deviceCount: simDeviceCount,
      );
      coord = coord_;
      appCtx = appCtx_;
      simDevicePool = pool_;
      globalHostPortHandler = null;
      // The harness seeds its local electrs URL here (regtest only); point the regtest wallet
      // at it via the existing setter so "receive bitcoin" syncs over the sim's own node. No
      // effect on other networks, and absent (offline sim) when the harness didn't start one.
      const simRegtestElectrum = String.fromEnvironment(
        'SIM_REGTEST_ELECTRUM_URL',
      );
      const simRegtestControl = String.fromEnvironment(
        'SIM_REGTEST_CONTROL_SOCKET',
      );
      if (simRegtestElectrum.isNotEmpty) {
        simRegtestElectrumUrl = simRegtestElectrum;
        simRegtestControlSocket = simRegtestControl.isEmpty
            ? null
            : simRegtestControl;
        final regtest = BitcoinNetwork.fromString(string: 'regtest')!;
        await appCtx_.settings.setElectrumServers(
          network: regtest,
          primary: simRegtestElectrum,
          backup: simRegtestElectrum,
        );
        await appCtx_.settings.setElectrumEnabled(
          network: regtest,
          enabled: ElectrumEnabled.primaryOnly,
        );
      }
    } else if (Platform.isAndroid) {
      final (coord_, appCtx_, ffiserial) = await api.loadHostHandlesSerial(
        appDir: appDirPath,
      );
      globalHostPortHandler = HostPortHandler(ffiserial);
      coord = coord_;
      appCtx = appCtx_;
    } else {
      final (coord_, appCtx_) = await api.load(appDir: appDirPath);
      coord = coord_;
      appCtx = appCtx_;
      globalHostPortHandler = null;
    }
    coord.startThread();
  } on PanicException catch (e) {
    startupError = "rust panic'd with: ${e.message}";
  } on AnyhowException catch (e, stacktrace) {
    startupError = "rust error: ${e.message}\n$stacktrace";
  } catch (error, stacktrace) {
    startupError = "$error\n$stacktrace";
    log(level: LogLevel.info, message: "startup failed with $startupError");
  }

  if (startupError != null) {
    runApp(MyApp(startupError: startupError));
  } else {
    GlobalStreams.deviceListSubject.forEach((update) {
      // If we detect a device that's in recovery mode we should tell it to exit
      // ASAP. Right now we don't confirm with the user this action but maybe in
      // the future we will.
      for (var change in update.changes) {
        if (change.kind == DeviceListChangeKind.recoveryMode &&
            change.device.recoveryMode) {
          final deviceId = change.device.id;
          () async {
            final SymmetricKey encryptionKey;
            try {
              encryptionKey = await SecureKeyProvider.getEncryptionKey();
            } on PlatformException catch (e) {
              final expected = e.code == 'NO_LOCK_SCREEN';
              log(
                level: expected ? LogLevel.info : LogLevel.error,
                message:
                    "skipping exitRecoveryMode for $deviceId: ${e.code} (${e.message})",
              );
              final ctx = rootNavKey.currentContext;
              if (ctx != null) {
                showErrorSnackbar(
                  ctx,
                  expected
                      ? "Couldn't take device out of recovery mode: screen lock required."
                      : "Couldn't take device out of recovery mode: ${e.message ?? e.code}",
                );
              }
              return;
            }
            coord.exitRecoveryMode(
              deviceId: deviceId,
              encryptionKey: encryptionKey,
            );
          }();
        }
      }

      // we want to stop the app from sleeping on mobile if there's a device plugged in.
      if (Platform.isLinux) {
        return; // not supported by wakelock
      }
      if (update.state.devices.isNotEmpty) {
        WakelockPlus.enable();
      } else {
        WakelockPlus.disable();
      }
    });
    // Lock orientation to portrait mode only
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(systemNavigationBarColor: Colors.transparent),
    );

    final mainWidget = buildMainWidget(appCtx!, logStream);
    runApp(mainWidget);
  }
}

Widget buildMainWidget(AppCtx appCtx, Stream<String> logStream) {
  return FrostsnapContext(
    appCtx: appCtx,
    logStream: logStream,
    defaultNetwork: simRegtestElectrumUrl != null
        ? BitcoinNetwork.regtest
        : BitcoinNetwork.bitcoin,
    child: SettingsContext(
      settings: appCtx.settings,
      child: SuperWalletContext(appCtx: appCtx, child: MyApp()),
    ),
  );
}

class MyApp extends StatefulWidget {
  final String? startupError;

  const MyApp({super.key, this.startupError});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final Future<List<void>> googleFontsPending;
  late ColorScheme colorScheme;

  void _setColorTheme() => colorScheme = ColorScheme.fromSeed(
    brightness: Brightness.dark,
    seedColor: seedColor,
  );

  @override
  void initState() {
    super.initState();
    googleFontsPending = GoogleFonts.pendingFonts([
      GoogleFonts.notoSansMono(),
      GoogleFonts.notoSansTextTheme(),
    ]);
    _setColorTheme();
  }

  @override
  void reassemble() {
    super.reassemble();
    _setColorTheme();
  }

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    final baseTheme = ThemeData(useMaterial3: true, colorScheme: colorScheme);

    return FutureBuilder(
      future: googleFontsPending,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Center(child: CircularProgressIndicator());
        }
        final textTheme = GoogleFonts.notoSansTextTheme(baseTheme.textTheme);

        return MaterialApp(
          navigatorKey: rootNavKey,
          scaffoldMessengerKey: rootScaffoldMessengerKey,
          title: 'Frostsnap',
          theme: baseTheme.copyWith(
            colorScheme: colorScheme,
            textTheme: textTheme,
          ),
          // The sim device tray docks BESIDE the app's Navigator (not inside it),
          // so the app's fullscreen dialogs/overlays — which render in the
          // Navigator's own Overlay (the `child`) — stay confined to the app pane
          // and never cover the tray. The tray must always be interactable so the
          // device can be driven while a dialog (e.g. the keygen Security Check) is up.
          builder: (context, child) {
            final app = child ?? const SizedBox.shrink();
            final pool = simDevicePool;
            if (!kSim || pool == null) return app;
            return Row(
              textDirection: TextDirection.ltr,
              children: [
                Expanded(child: app),
                SimDeviceTray(
                  pool: pool,
                  regtestControlSocket: simRegtestControlSocket,
                ),
              ],
            );
          },
          home: widget.startupError == null
              ? const MyHomePage()
              : StartupErrorWidget(error: widget.startupError!),
          debugShowCheckedModeBanner: false,
        );
      },
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  late final GlobalKey<ScaffoldState> scaffoldKey;
  late final WalletListController walletListController;
  late final ConfettiController confettiController;

  @override
  void initState() {
    super.initState();
    scaffoldKey = GlobalKey();
    walletListController = WalletListController(
      keyStream: GlobalStreams.keyStateSubject,
    );
    confettiController = ConfettiController(duration: Duration(seconds: 4));
  }

  @override
  void dispose() {
    confettiController.dispose();
    walletListController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The sim device tray is hoisted to MaterialApp.builder (above the app's
    // dialog/overlay layer), so the home body here is unchanged from production.
    return HomeContext(
      scaffoldKey: scaffoldKey,
      walletListController: walletListController,
      confettiController: confettiController,
      child: Stack(
        alignment: AlignmentDirectional.center,
        children: [
          const WalletHome(),
          Center(
            child: ConfettiWidget(
              confettiController: confettiController,
              blastDirectionality: BlastDirectionality.explosive,
              numberOfParticles: 101,
            ),
          ),
        ],
      ),
    );
  }
}

class StartupErrorWidget extends StatefulWidget {
  final String error;

  const StartupErrorWidget({super.key, required this.error});

  @override
  State<StartupErrorWidget> createState() => _StartupErrorWidgetState();
}

class _StartupErrorWidgetState extends State<StartupErrorWidget> {
  final List<String> _logs = [];
  StreamSubscription<String>? _subscription;

  @override
  void initState() {
    super.initState();
    // Delay the context access until after the first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final logStream = FrostsnapContext.of(context)?.logStream;

      if (logStream != null) {
        _subscription = logStream.listen((log) {
          setState(() {
            _logs.add(log);
          });
        });
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  /// Combines all logs and the error message into a single string.
  String get _combinedErrorWithLogs {
    if (_logs.isEmpty) {
      return widget.error;
    }

    // Format each log entry
    final String logsText = _logs.join('\n');

    // Combine logs with the error message
    return '$logsText\n------------------\n${widget.error}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('Startup Error')),
      body: Padding(
        padding: EdgeInsets.all(16.0),
        child: Center(
          child: SingleChildScrollView(
            // To handle overflow if logs are extensive
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Text(
                  'STARTUP ERROR',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  "Sorry! Something has gone wrong with the app. Please report this directly to the frostsnap team.",
                  style: theme.textTheme.titleMedium,
                ),
                SizedBox(height: 20),
                Container(
                  width:
                      double.infinity, // Ensure the container takes full width
                  padding: EdgeInsets.all(8.0),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(4.0),
                    border: Border.all(),
                  ),
                  child: SelectableText(_combinedErrorWithLogs),
                ),
                SizedBox(height: 20),
                CopyIconButton(
                  data: _combinedErrorWithLogs,
                  icon: Icons.content_copy,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
