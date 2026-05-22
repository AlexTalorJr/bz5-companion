import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import 'data/database.dart';
import 'services/connection.dart';
import 'services/cost_settings.dart';
import 'services/cloud_sync_service.dart';
import 'screens/home.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _requestPermissions();
  final db = AppDatabase();
  final svc = ConnectionService(db);
  runApp(BZ5App(db: db, svc: svc));
}

Future<void> _requestPermissions() async {
  await [
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.location, // на старых Android для BLE
  ].request();
}

class BZ5App extends StatefulWidget {
  final AppDatabase db;
  final ConnectionService svc;

  const BZ5App({super.key, required this.db, required this.svc});

  @override
  State<BZ5App> createState() => _BZ5AppState();
}

class _BZ5AppState extends State<BZ5App> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    // v0.1.22: register lifecycle observer so we can retry auto-connect
    // when the app returns to foreground. Fixes the bug where user opens
    // the app at home (out of BLE range), sees "адаптер не найден",
    // closes the app, walks to car, opens the app again — and nothing
    // happens. Now the second foreground entry triggers a fresh scan.
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // Fire-and-forget. The service throttles internally (30 s minimum
      // between attempts) so flipping focus rapidly doesn't queue scans.
      // No-op if already connected, or if user disabled auto-connect.
      widget.svc.tryAutoConnect();
    }
  }

  @override
  Widget build(BuildContext context) {
    // v0.1.27: wrap in MultiProvider so reactive Cost-settings are
    // available alongside ConnectionService. CostSettings is its own
    // ChangeNotifier (see services/cost_settings.dart) — kept separate
    // from ConnectionService per CLAUDE.md (don't touch the 3519-LOC
    // BLE god-object).
    //
    // v0.1.28: CloudSyncService added as a third independent provider.
    // It reads Drift tables read-only (never writes back) and pushes
    // to the bz5-bridge server. Lives entirely independently of
    // ConnectionService — bridge work is additive per CLAUDE.md.
    // Its .init() is fire-and-forget; first build shows
    // CloudSyncStatus.disconnected until prefs/keystore loads complete.
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ConnectionService>.value(value: widget.svc),
        ChangeNotifierProvider<CostSettings>(
          // load() fires async; UI uses CostSettings.isLoaded to avoid
          // briefly displaying a 0 value as "not configured" before
          // prefs actually arrive. In practice load is sub-100ms so
          // this only matters on the very first frame.
          create: (_) => CostSettings()..load(),
        ),
        ChangeNotifierProvider<CloudSyncService>(
          create: (_) => CloudSyncService(db: widget.db)..init(),
        ),
      ],
      child: MaterialApp(
        title: 'BZ5 Companion',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1976D2),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
          fontFamily: 'Roboto',
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
