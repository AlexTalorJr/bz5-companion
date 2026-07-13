import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import 'data/database.dart';
import 'services/account_auth_service.dart';
import 'services/app_diag_log.dart';
import 'services/hal_telemetry_service.dart';
import 'services/connection.dart';
import 'services/cost_settings.dart';
import 'services/cloud_sync_service.dart';
import 'services/vehicle_catalog_service.dart';
import 'services/bridge_diag_service.dart';
import 'services/locale_service.dart';
import 'screens/home.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // v0.1.29+122: capture every debugPrint line into the in-app ring
  // buffer BEFORE any service init, so startup lines (CloudSync init,
  // HAL engine selection, locale resolution) are readable on the
  // ADB-less head unit via Settings → App log & sync state.
  AppDiagLog.instance.install();
  // v0.1.29+49: initialize the ru locale for intl BEFORE any DateFormat
  // call. Without this, `DateFormat.MMM('ru').format(...)` throws a
  // LocaleDataException at the first render. In debug that surfaces as
  // a red error widget; in release Flutter swallows the throw and the
  // failing widget renders as a BLANK WHITE BOX with the slot's
  // dimensions — exactly the "белый прямоугольник" the owner saw on
  // the Trends cost card. Three sites in trends.dart use MMM('ru'):
  // _textFallback for <3-month cost card (the one that blanked), the
  // ≤400d branch of _timeSideTitles, and _periodBarSideTitles for ≥3
  // months with a single calendar year. All three depended on this
  // initializer existing — it never did. await before runApp so the
  // first frame is safe.
  await initializeDateFormatting('ru');
  // v0.1.29+58: resolve + load the app language BEFORE the first frame.
  // load() is a single SharedPreferences read (sub-ms after the prefs
  // file is cached by _requestPermissions/plugins init); awaiting here
  // avoids an en→ru flash on Russian-configured installs.
  final localeService = LocaleService();
  await localeService.load();
  await _requestPermissions();
  final db = AppDatabase();
  final svc = ConnectionService(db);
  runApp(BZ5App(db: db, svc: svc, localeService: localeService));
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
  final LocaleService localeService;

  const BZ5App(
      {super.key,
      required this.db,
      required this.svc,
      required this.localeService});

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
    //
    // v0.1.29+15: BridgeDiagService added as a fourth provider — the
    // Plane A command channel from CLIENT_API.md §7. Independent of
    // CloudSyncService but reads the same client_token from secure
    // storage. Off by default; user toggles it from Settings.
    // Its .init() is also fire-and-forget.
    //
    // v0.1.29+17 (Turn B): now takes ConnectionService via constructor
    // injection so it can dispatch bleStart*/bleStopActiveOperation
    // commands. Logical dependency — Plane A drives the car through
    // the same channels ConnectionService already manages.
    // v0.1.29+58: LocaleService added as a fifth provider — app
    // language (System/Русский/English). Created and loaded in main()
    // so the first frame is already in the right language. Localized
    // screens subscribe via context.watch<LocaleService>() themselves;
    // a MaterialApp-level rebuild would NOT reach them through the
    // `home: const HomeScreen()` const subtree (Flutter skips identical
    // const children), so per-screen watch is the rebuild mechanism.
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ConnectionService>.value(value: widget.svc),
        ChangeNotifierProvider<LocaleService>.value(
            value: widget.localeService),
        ChangeNotifierProvider<CostSettings>(
          // load() fires async; UI uses CostSettings.isLoaded to avoid
          // briefly displaying a 0 value as "not configured" before
          // prefs actually arrive. In practice load is sub-100ms so
          // this only matters on the very first frame.
          create: (_) => CostSettings()..load(),
        ),
        ChangeNotifierProvider<CloudSyncService>(
          // v0.1.38+137: back to the plain create. The +136 attempt to
          // ctx.read<HalTelemetryService> from HERE was a direction
          // error — Provider.of walks UP the tree, HAL sits BELOW.
          // The HU-gate callback is wired inside the HAL provider's
          // create instead (see below, same pattern as halOwnsTripCheck).
          create: (_) => CloudSyncService(db: widget.db)..init(),
        ),
        // v0.1.36+135: server vehicle catalog (S8, public endpoint).
        // Separate lightweight service by design — CloudSyncService owns
        // the authenticated device plane; the catalog is unauthenticated
        // UI-hint data with its own 24h cache. baseUrl is read through a
        // callback at fetch time so a custom base URL from settings is
        // respected (same callback-not-import rule as HAL below).
        ChangeNotifierProvider<VehicleCatalogService>(
          create: (ctx) => VehicleCatalogService(
            baseUrl: () => ctx.read<CloudSyncService>().baseUrl,
          )..init(),
        ),
        ChangeNotifierProvider<BridgeDiagService>(
          create: (_) => BridgeDiagService(svc: widget.svc)..init(),
        ),
        // v0.1.29+124 (C2): account layer (email OTP, CLIENT_API §1.1).
        // Independent of CloudSyncService/BridgeDiagService per the
        // §0/§10 rule — phone-side credential, own lifecycle. init()
        // is a local secure-storage read (no network).
        ChangeNotifierProvider<AccountAuthService>(
          create: (_) => AccountAuthService()..init(),
        ),
        // v0.1.29+64: HAL push-telemetry (SPEED overlapping pilot). Owns
        // the live HAL stream + source mode; feeds the DISPLAYED speedo
        // only — trip aggregates stay on OBD2 ConnectionService.
        // v0.1.29+87: pass the DB + a current-trip-id reader so the HAL
        // stream is throttle-logged to hal_samples for diagnostics.
        ChangeNotifierProvider<HalTelemetryService>(
          // v0.1.38+137: `_` → `ctx` — the create body now reads
          // CloudSyncService (registered above) to wire the HU-gate.
          create: (ctx) {
            final hal = HalTelemetryService(
              diagDb: widget.db,
              currentTripId: () => widget.svc.currentTripId,
              // v0.1.29+106: HAL trip ownership keys off the dongle, not the
              // mode. This bool callback reads ConnectionService.isBleConnected
              // (HAL → connection is the allowed one-way direction, like
              // currentTripId). dongle present → halOwnsTrip false → OBD2
              // creates the trip; absent → HAL owns it in any mode (fixes the
              // no-trip-in-auto-without-dongle bug). AA2 holds: a callback,
              // never an import of the HAL class.
              dongleConnected: () => widget.svc.isBleConnected,
            );
            // v0.1.29+99: wire the trip-ownership arbiter. The OBD2
            // ConnectionService is built before HAL (above), so this is set
            // here once HAL exists. With it, only ONE tracker writes Trips
            // per source mode — halOnly/auto-live → HAL, obd2Only → OBD2 —
            // killing the two-simultaneous-ACTIVE-trips bug. AA2 holds: svc
            // receives a bool callback, never the HAL class.
            widget.svc.halOwnsTripCheck = () => hal.halOwnsTrip;
            // v0.1.38+137: HU-gate for sync-down (F3). Wired HERE — the
            // HAL provider's ctx CAN see CloudSyncService (it's above in
            // the MultiProvider list), the reverse direction is what
            // crashed +136. Same shape as halOwnsTripCheck one line up:
            // a bool callback, never the HAL class itself (AA2).
            ctx.read<CloudSyncService>().isHeadUnitCheck =
                () => hal.canUseHal;
            hal.init();
            return hal;
          },
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
