import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import 'data/database.dart';
import 'services/connection.dart';
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
    return ChangeNotifierProvider.value(
      value: widget.svc,
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
