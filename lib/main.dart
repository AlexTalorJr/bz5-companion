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

class BZ5App extends StatelessWidget {
  final AppDatabase db;
  final ConnectionService svc;

  const BZ5App({super.key, required this.db, required this.svc});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: svc,
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
