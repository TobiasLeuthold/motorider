import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'data/csv_seed.dart';
import 'data/database.dart';
import 'data/fillup_repository.dart';
import 'screens/home_shell.dart';
import 'services/nas_settings.dart';
import 'services/sync_service.dart';
import 'theme.dart';

final FillUpRepository fillUpRepo = FillUpRepository(AppDatabase.instance);

// Initialized in [main] before [runApp]. Accessed from screens like
// settings_screen.dart. Kept as `late final` globals to match the existing
// fillUpRepo pattern — fine for a single-user personal app.
late final NasSettings nasSettings;
late final SyncService syncService;

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

  nasSettings = await NasSettings.load();
  syncService = SyncService(fillUpRepo, nasSettings);

  // Kick off an opportunistic sync at startup. Not awaited — if the NAS is
  // unreachable (no Tailscale, plane mode, …) the UI still renders, and the
  // failure is surfaced in Settings via the sync status stream.
  if (nasSettings.hasCredentials) {
    // ignore: unawaited_futures
    syncService.syncOnce();
  }

  runApp(const MotoRiderApp());
}

class MotoRiderApp extends StatelessWidget {
  const MotoRiderApp({super.key});

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
