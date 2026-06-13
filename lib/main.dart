import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'data/csv_seed.dart';
import 'data/database.dart';
import 'data/fillup_repository.dart';
import 'data/ride_repository.dart';
import 'data/route_repository.dart';
import 'screens/home_shell.dart';
import 'services/nas_settings.dart';
import 'services/ride_tracker.dart';
import 'services/sync_service.dart';
import 'theme.dart';

final FillUpRepository fillUpRepo = FillUpRepository(AppDatabase.instance);
final RideRepository rideRepo = RideRepository(AppDatabase.instance);
final RouteRepository routeRepo = RouteRepository(AppDatabase.instance);

// Initialized in [main] before [runApp]. Accessed from screens like
// settings_screen.dart. Kept as `late final` globals to match the existing
// fillUpRepo pattern — fine for a single-user personal app.
late final NasSettings nasSettings;
late final SyncService syncService;
late final RideTracker rideTracker;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Surface the FIRST exception clearly in the console (the default
  // logging buries it under a cascade of secondary layout errors).
  FlutterError.onError = (FlutterErrorDetails details) {
    // ignore: avoid_print
    print('\n[motorider] ════ FlutterError: ${details.exception} ════');
    if (details.stack != null) {
      // ignore: avoid_print
      print(details.stack);
      // ignore: avoid_print
      print('[motorider] ══════════════════════════════════════════\n');
    }
    FlutterError.presentError(details);
  };

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await initializeDateFormatting('de');

  await seedFromCsvIfEmpty(fillUpRepo);
  await fillUpRepo.primeStream();
  await rideRepo.primeStream();
  await routeRepo.primeStream();

  // Self-heal cached ride stats after stats-algorithm changes (notably the
  // Doppler-based max-speed fix). Not awaited — rides update in place and the
  // list re-emits as rows are corrected.
  // ignore: unawaited_futures
  rideRepo.recomputeAllStats();

  nasSettings = await NasSettings.load();
  syncService = SyncService(fillUpRepo, rideRepo, nasSettings);
  rideTracker = RideTracker(rideRepo);

  // Kick off an opportunistic sync at startup. Not awaited — if the NAS is
  // unreachable (no Tailscale, plane mode, …) the UI still renders, and the
  // failure is surfaced in Settings via the sync status stream.
  if (nasSettings.hasCredentials) {
    // ignore: unawaited_futures
    syncService.syncOnce();
  }

  runApp(const MotoRiderApp());
}

class MotoRiderApp extends StatefulWidget {
  const MotoRiderApp({super.key});

  @override
  State<MotoRiderApp> createState() => _MotoRiderAppState();
}

class _MotoRiderAppState extends State<MotoRiderApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Foreground after backgrounding → opportunistically pull anything new
    // and push anything that piled up while we were away.
    if (state == AppLifecycleState.resumed && nasSettings.hasCredentials) {
      // ignore: unawaited_futures
      syncService.syncOnce();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MotoRider',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const HomeShell(),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('de', 'CH'), Locale('en')],
      locale: const Locale('de', 'CH'),
    );
  }
}
