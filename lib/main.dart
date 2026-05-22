import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'data/csv_seed.dart';
import 'data/database.dart';
import 'data/fillup_repository.dart';
import 'screens/home_shell.dart';
import 'theme.dart';

final FillUpRepository fillUpRepo = FillUpRepository(AppDatabase.instance);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await initializeDateFormatting('de');

  await seedFromCsvIfEmpty(fillUpRepo);
  await fillUpRepo.primeStream();

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
