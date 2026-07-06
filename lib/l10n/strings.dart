/// v0.1.29+58: hand-rolled localization mechanism (EN/RU).
///
/// Deliberately NOT flutter_localizations / easy_localization / intl ARB
/// codegen — those drag a build-step and per-locale delegate machinery
/// for what is, in this app, a flat string table with two languages.
/// `intl` stays in the project for date formatting only (the +49
/// `initializeDateFormatting('ru')` call in main.dart is untouched).
///
/// Contract:
///   * `S.locale` is a static field holding the RESOLVED locale code
///     ('en' or 'ru' — never 'system'). LocaleService owns resolution
///     (system → platform language → ru if ru else en) and writes this
///     field BEFORE calling notifyListeners(), so any widget rebuilt by
///     the notification already sees the new language.
///   * `S.of(key)` lookup chain:
///       locale == 'ru' →  _ru[key] ?? _en[key] ?? key
///       locale == 'en' →  _en[key] ?? key
///     English is the fallback (head-unit system locale is Chinese, so
///     'system' resolves to 'en' there — agreed design).
///   * Keys are flat dotted strings. Placeholders use `{name}` and are
///     substituted at the call site via `.replaceFirst('{name}', ...)`.
///
/// What is NOT translated (project rule): DID / ECU / UDS / BLE / SOC /
/// SOH / DTC / HAL terminology, hex literals, adapter names, tool names
/// that are de-facto proper nouns (Raw Data, ECU Explorer, DID Sweep,
/// Live Log, HAL Explorer).
library;

class S {
  S._(); // static-only

  /// Resolved locale: 'en' | 'ru'. Written by LocaleService.
  static String locale = 'en';

  static String of(String key) {
    if (locale == 'ru') {
      return _ru[key] ?? _en[key] ?? key;
    }
    return _en[key] ?? key;
  }

  // ───────────────────────────── EN ─────────────────────────────
  static const Map<String, String> _en = {
    // Common
    'common.cancel': 'Cancel',
    'common.save': 'Save',
    'common.continue': 'Continue',
    'common.ok': 'OK',
    'common.close': 'Close',
    'common.loading': 'Loading…',

    // Navigation — phone bottom bar
    'nav.dashboard': 'Dashboard',
    'nav.cells': 'Cells',
    'nav.history': 'History',
    'nav.settings': 'Settings',
    // Navigation — head-unit rail
    'nav.driving': 'Driving',
    'nav.vehicle': 'Vehicle',

    // Relative time
    'rel.s_ago': '{n}s ago',
    'rel.m_ago': '{n}m ago',
    'rel.h_ago': '{n}h ago',
    'rel.d_ago': '{n}d ago',

    // Settings — screen & sections
    'settings.title': 'Settings',
    'settings.section.connection': 'Connection',
    'settings.datasource.title': 'Where data comes from',
    'settings.datasource.subtitle': 'Where live values come from',
    'settings.datasource.auto': 'Auto (prefer HAL, fall back to OBD2)',
    'settings.datasource.hal': 'From the car',
    'settings.datasource.obd2': 'Through the adapter',
    'settings.datasource.hal_unavailable': 'Car data is not available right now',
    'settings.datasource.hal_no_platform':
        'On this device only the adapter is available',
    'datasource.hal_dead_hint':
        'HAL stream is down — Settings → switch to OBD2, or restart the app',
    'settings.section.cost': 'Cost',
    'settings.section.vehicle': 'Vehicle',
    'settings.section.app': 'App',
    'settings.section.language': 'Язык / Language',

    // Settings — connection
    'settings.adapter.title': 'ELM327 BLE adapter',
    'settings.adapter.not_connected': 'Not connected',
    'settings.autoconnect.title': 'Auto-connect at startup',
    'settings.autoconnect.subtitle':
        'Connect to the remembered adapter when the app starts',
    'settings.scan.busy': 'Scanning…',
    'settings.scan.start': 'Find adapter',
    'settings.scan.reconnect_last': 'Reconnect to last adapter',
    'settings.disconnect': 'Disconnect',
    'settings.connected_snack': 'Connected! Switch to Dashboard',
    // v0.1.29+110: localized connection plaque (was raw enum names)
    'settings.conn.connected': 'Connected',
    'settings.conn.connecting': 'Connecting…',
    'settings.conn.scanning': 'Searching…',
    'settings.conn.error': 'Connection error',
    'settings.conn.disconnected': 'Not connected',
    'settings.conn.adapter': 'Adapter {addr}',
    'settings.device.unknown': 'Unknown device',
    // v0.1.29+110: Cloud services entry (О1) + 4-state menu summary
    'settings.cloud_services.title': 'Cloud services',
    'cloud.menu.connected': 'Connected',
    'cloud.menu.disconnected': 'Not connected',
    'cloud.menu.auth_error': 'Sign-in error',
    'cloud.menu.paused': 'Paused',

    // Settings — language (v0.1.29+59: System mode removed — explicit
    // EN default / RU switch only)
    'settings.language.ru': 'Русский',
    'settings.language.en': 'English',

    // About — hidden Advanced unlock (v0.1.29+59)
    'about.title': 'About',
    'about.adv.progress': '{n} taps to unlock Advanced',
    'about.adv.unlocked': 'Advanced tools unlocked — see Settings',

    // Settings — cost
    'settings.cost.per_kwh.title': 'Cost per kWh',
    'settings.cost.per_kwh.value': '{amount} per kWh',
    'settings.cost.per_kwh.unset': 'Not set — trip cost is not displayed',
    'settings.cost.currency.title': 'Currency symbol',
    'settings.cost.currency.value': 'Current: "{symbol}" (example: {example})',
    'dialog.cost.title': 'Cost of 1 kWh',
    'dialog.cost.label': 'Price',
    'dialog.cost.hint': 'e.g. 5.50',
    'dialog.cost.helper': 'In your currency (symbol is set below). '
        '0 = hide trip cost entirely.',
    'dialog.currency.title': 'Currency symbol',
    'dialog.currency.label': 'Symbol',
    'dialog.currency.quick': 'Quick pick:',

    // Settings — vehicle
    'settings.dtc.title': 'Diagnostics (DTC)',
    'settings.dtc.subtitle': 'Read trouble codes from all ECUs (read-only)',
    'settings.about.title': 'About / Pack specification',
    'settings.about.subtitle':
        'BZ5 battery pack details, DID sources, experiments',

    // Settings — data
    'settings.data.title': 'Data & Export',
    'settings.data.subtitle':
        'Export trips/snapshots/samples to USB or cloud, clear data',

    // Settings — advanced
    'settings.advanced.title': 'Advanced',
    'settings.advanced.subtitle': 'Research and app-diagnostic tools',
    'settings.rawdata.subtitle': 'Live DID table + diagnostics sweep (wide view)',
    'settings.ecu.subtitle': 'DID registry across all ECUs, live values',
    'settings.sweep.subtitle': 'In-car ECU probe — presets and custom ranges',
    'settings.livelog.subtitle': 'Time-series polling, up to 7 DIDs at once',
    'settings.polldiag.subtitle': 'Pack current read counters, gaps, null rate',
    'settings.appdiag.title': 'App log & sync state',
    'settings.appdiag.subtitle':
        'debugPrint ring buffer + CloudSync internals (dev)',
    'settings.hal.subtitle': 'Native BYD HAL probe — status, subscriptions, logs',

    // App diagnostics screen (v0.1.29+122)
    'appdiag.title': 'App diagnostics',
    'appdiag.cloud.header': 'Cloud sync state',
    'appdiag.log.header': 'App log',
    'appdiag.copy': 'Copy',
    'appdiag.export': 'Export',
    'appdiag.clear': 'Clear',
    'appdiag.copied': 'Log copied to clipboard',

    // Account (email OTP) — v0.1.29+124 (C2)
    'account.title': 'Account',
    'account.settings_subtitle': 'Email sign-in, device list & revoke',
    'account.intro': 'Sign in with your email to manage devices linked to '
        'this bridge account. Only addresses allowed by the bridge owner '
        'can sign in.',
    'account.email_hint': 'Email',
    'account.send_code': 'Send code',
    'account.code_sent_neutral': 'If {email} is allowed to sign in, a code '
        'was sent to it (valid 10 min). Check the Spam folder too. For '
        'security reasons this screen cannot confirm whether the mail was '
        'actually sent.',
    'account.code_hint': 'Code from the email',
    'account.verify': 'Sign in',
    'account.resend': 'Send again',
    'account.resend_in': 'Send again in',
    'account.resend_note': 'A new code voids the previous one — only the '
        'latest code works.',
    'account.change_email': 'Use a different email',
    'account.locked_for': 'Rate-limited, wait',
    'account.signed_in_as': 'Signed in',
    'account.logout': 'Sign out',
    'account.devices_header': 'Devices',
    'account.devices_empty': 'No devices linked to this account yet.',
    'account.last_heartbeat': 'last seen',
    'account.revoked': 'REVOKED',
    'account.revoke': 'Revoke',
    'account.revoke_confirm_title': 'Revoke device access?',
    'account.revoke_confirm_body': '"{name}" will lose cloud access and '
        'stop syncing. Its local data is NOT deleted. This cannot be '
        'undone from the app.',
    'account.err_invalid_code': 'Wrong, expired (10 min) or already used '
        'code. After 5 wrong attempts the code burns — request a new one.',
    'account.err_not_allowed': 'This address is not allowed to sign in. '
        'Ask the bridge owner to add it to the allowlist.',
    'account.err_rate_limited': 'Too many requests — wait a bit and retry '
        '(limit: 5 codes per hour per address).',
    'account.err_not_configured': 'Accounts are not set up on this bridge '
        'yet (server-side). Ask the owner.',
    'account.err_session': 'The session was ended (token reuse or expiry). '
        'Please sign in again.',
    'account.err_bad_email': 'Enter a valid email address.',
    'account.err_network': 'Network error — check the connection and retry.',
    'account.err_generic': 'Request failed',
    'account.claim_header': 'Pair a device',
    'account.claim_hint': 'On the device: Settings → Device pairing → '
        'Get code, then type that code here.',
    'account.claim_code_hint': 'Code from the device',
    'account.claim_button': 'Pair',
    'account.claim_ok': 'Device paired to the account',
    'account.claim_invalid': 'Unknown or expired code — get a fresh one '
        'on the device (valid 5 min).',
    'account.claim_no_vehicle': 'The account has no default vehicle — '
        'contact the bridge owner.',

    // Device pairing screen — v0.1.29+127 (C3)
    'pairing.title': 'Device pairing',
    'pairing.settings_subtitle': 'Link this device to an account '
        '(code on screen → approve on the phone)',
    'pairing.intro_fresh': 'This install has no cloud credential yet. '
        'Get a code, approve it on a signed-in phone — a token will be '
        'issued automatically and history restore will start. No manual '
        'token entry.',
    'pairing.intro_live': 'This device already syncs. Pairing will '
        'attach it to the account — the token stays unchanged, data is '
        'not touched.',
    'pairing.kind_headunit': 'Head unit',
    'pairing.kind_phone': 'Phone',
    'pairing.get_code': 'Get code',
    'pairing.enter_on_phone': 'On the signed-in phone: Settings → Cloud '
        'services → Account → Pair a device — and type this code:',
    'pairing.expires_in': 'Code valid for',
    'pairing.paired_fresh': 'Paired! Token issued — restoring history…',
    'pairing.paired_live': 'Paired! Device attached to the account.',
    'pairing.restore_status': 'Restore',
    'pairing.expired': 'The code expired (5 min). Get a new one.',
    'pairing.error': 'Pairing failed',
    'pairing.retry': 'Try again',
    'common.done': 'Done',

    // Cloud backup card
    'cloud.title': 'Cloud backup',
    'cloud.intro': 'Save trip history and BMS snapshots to the bz5-bridge so '
        'they survive head-unit reinstalls. Setup needs a token '
        'from the bridge owner; Restore needs the previous '
        "device's client_token.",
    'cloud.setup_btn': 'Set up cloud backup',
    'cloud.restore_btn': 'Restore from cloud',
    'cloud.enabled': 'Enabled',
    'cloud.unknown_vehicle': '(unknown vehicle)',
    'cloud.last_sync': 'Last sync',
    'cloud.never': 'never',
    'cloud.pending': 'Pending: {t} trips, {s} snapshots, {w} sweeps, '
        '{l} live-logs',
    'cloud.sync_now': 'Sync now',
    'cloud.force_resync': 'Force full resync',
    'cloud.backup_token': 'Backup token',
    'cloud.last_restore': 'Last restore',
    // Cloud status labels
    'cloud.status.not_set_up': 'Not set up',
    'cloud.status.paused': 'Paused',
    'cloud.status.up_to_date': 'Up to date',
    'cloud.status.caught_up': 'Caught up, scheduled',
    'cloud.status.syncing': 'Syncing…',
    'cloud.status.error': 'Error — retrying',
    'cloud.status.auth_failed': 'Auth failed — re-register required',
    // Restore progress lines (inline card)
    'cloud.restoring.validating': 'Restoring: validating token…',
    'cloud.restoring.trips': 'Restoring trips: {a} new / {b} fetched',
    'cloud.restoring.snapshots':
        'Restoring snapshots: {a} new / {b} fetched (trips: {c})',
    'cloud.restoring.generic': 'Restoring…',

    // Cloud setup dialog
    'cloud.setup.title': 'Cloud backup — Setup',
    'cloud.setup.intro': 'Enter the setup token provided by the bridge owner. '
        'This token can only be used once; the owner will need '
        'to reissue it if you re-register later.',
    'cloud.setup.token_label': 'Setup token',
    'cloud.setup.advanced': 'Advanced',
    'cloud.setup.url_label': 'Bridge URL',
    'cloud.setup.failed': 'Setup failed',
    'cloud.setup.no_vehicles.title': 'No vehicles',
    'cloud.setup.no_vehicles.body':
        'The bridge has no vehicles configured. Ask the owner to seed one.',
    'cloud.setup.choose_vehicle': 'Choose vehicle',
    'cloud.setup.reg_failed': 'Registration failed',
    'cloud.setup.connected_snack':
        'Connected to {name}. First sync will run in the background.',

    // Force resync dialog
    'cloud.resync.title': 'Force full resync?',
    'cloud.resync.body':
        'This re-uploads every trip, snapshot, sweep and live-log '
        'from local DB. The bridge will dedupe — old records '
        'already on the server are not duplicated. Useful after '
        'a Drift restore. May take a few minutes.',
    'cloud.resync.confirm': 'Force resync',

    // Disconnect dialog
    'cloud.disconnect.title': 'Disconnect from bridge?',
    'cloud.disconnect.body':
        'This removes the saved client token. Local Drift data '
        'stays intact. To re-enable you will need a fresh setup '
        'token from the bridge owner.',
    'cloud.disconnect.confirm': 'Disconnect',

    // Restore dialog
    'cloud.restore.title': 'Restore from cloud',
    'cloud.restore.intro': "Paste the previous device's client_token. The bridge "
        'owner can look this up server-side; it has the form '
        '<device_id>.<secret>. This will REPLACE the current '
        'cloud identity — pushes resume under the restored '
        'device.',
    'cloud.restore.token_label': 'Client token',
    'cloud.restore.rejected': 'Token rejected',
    'cloud.restore.replace.title': 'Replace cloud identity?',
    'cloud.restore.replace.device': 'Device: {id}',
    'cloud.restore.replace.body': 'After confirmation:\n'
        '  • current token is replaced (current registration '
        'becomes an orphan on the server — ask owner to revoke '
        'if desired)\n'
        '  • trips + snapshots are pulled into local Drift '
        'with dedup\n'
        '  • push cursors advance past max local id so '
        'restored rows are not re-uploaded',
    'cloud.restore.replace.warning':
        'If you have driven any trips on this install '
        'since reinstalling the app, those local records '
        'will stay in the app but will NOT be uploaded '
        'under the restored identity. (To avoid this, '
        'restore immediately after reinstall.)',
    'cloud.restore.replace.note':
        'Sweeps and live-log sessions are NOT restored in '
        'this version — they remain accessible only via '
        'admin inspection on the bridge.',
    'cloud.restore.confirm': 'Restore',
    // Restore progress dialog
    'cloud.restore.hdr.validating': 'Validating token…',
    'cloud.restore.hdr.fetch_trips': 'Fetching trips…',
    'cloud.restore.hdr.fetch_snapshots': 'Fetching snapshots…',
    'cloud.restore.hdr.done': 'Restore complete',
    'cloud.restore.hdr.cancelled': 'Restore cancelled',
    'cloud.restore.hdr.error': 'Restore failed',
    'cloud.restore.hdr.finished': 'Restore finished',
    'cloud.restore.line.trips': 'Trips: {a} new / {b} fetched',
    'cloud.restore.line.snapshots': 'Snapshots: {a} new / {b} fetched',
    'cloud.restore.done_snack': 'Restore complete: {t} trips, '
        '{s} snapshots inserted. Cloud sync resumed.',

    // Backup token dialog
    'cloud.token.none.title': 'No token to back up',
    'cloud.token.none.body':
        'There is no active client token in secure storage. '
        'Run Setup or Restore first.',
    'cloud.token.title': 'Backup client token',
    'cloud.token.intro': 'Save this token in a password manager. '
        'The server cannot recover it (sha256-hashed) — '
        "you'll need it to Restore after a head-unit "
        'reinstall.',
    'cloud.token.length': 'Length: {n} chars',
    'cloud.token.hide': 'Hide',
    'cloud.token.reveal': 'Reveal',
    'cloud.token.copy': 'Copy',
    'cloud.token.copied': 'Token copied to clipboard',

    // Bridge diagnostic card
    'bridge.title': 'Bridge diagnostic',
    'bridge.intro': 'Allows the bridge owner to push diagnostic commands to this '
        'device for sweep / live-log / native probe sessions. Uses the '
        'same registration as Cloud backup above — set that up first. '
        'Off by default.',
    'bridge.enable': 'Enable bridge diagnostic',
    'bridge.stats': 'Executed: {a}  ·  Rejected: {b}',
    'bridge.last': 'Last: {kind} ({when})',
    'bridge.status.off': 'Off',
    'bridge.status.register_first': 'Register via Cloud backup first',
    'bridge.status.listening': 'Listening for commands',
    'bridge.status.executing': 'Executing {kind}…',
    'bridge.status.error': 'Error — retrying',
    'bridge.status.auth_failed': 'Auth failed — re-register via Cloud backup',

    // ── v0.1.29+60: driver panels / dashboards ──
    'drv.speed': 'SPEED',
    'drv.soc': 'STATE OF CHARGE',
    'drv.this_trip': 'THIS TRIP',
    'drv.trip_cost': 'TRIP COST',
    'drv.cell.distance': 'distance',
    'drv.cell.energy': 'energy used',
    'drv.cell.consumption': 'consumption',
    'drv.cell.duration': 'duration',
    'drv.cell.peak': 'peak speed',
    'drv.cell.avg_moving': 'avg moving',
    'drv.cell.avg_speed': 'avg speed',
    'drv.calculating': 'calculating…',
    'drv.power': 'Power',
    'drv.regen': 'Regen',
    'drv.odo': 'Odo',
    'drv.cell_spread': 'Cell spread',
    'drv.hal_extras': 'MOTOR',
    'drv.cell.trip_a': 'trip A',
    'drv.cell.trip_b': 'trip B',
    'drv.cell.motor_rpm': 'motor rpm',
    'drv.cell.motor_torque': 'torque',
    'drv.cell.motor_power': 'motor power',
    'drv.cell.motor_temp': 'motor temp',
    'drv.cell.inverter_temp': 'inverter temp',
    'common.not_connected_title': 'Adapter not connected',
    'common.not_connected_hint': 'Open Settings and tap "Find adapter"',
    'common.no_data': 'No data',

    'dashw.pause_polling': 'Pause polling',
    'dashw.start_polling': 'Start polling',
    'dash.range': 'RANGE',
    'dash.packv_live': 'PACK VOLTAGE (LIVE)',
    'dash.nominal': 'NOMINAL',
    'dash.not_charging': 'Not charging',
    'dash.charging': 'CHARGING',
    'dash.connected': 'Connected',
    'dash.this_session': 'THIS SESSION',
    'dash.battery': 'BATTERY',
    'dash.odometer': 'ODOMETER',
    'dash.cycles': 'CYCLES',
    'dash.total_energy': 'TOTAL ENERGY',
    'dash.inverter': 'INVERTER',
    'dash.pawl_engaged': 'PAWL ENGAGED',
    'dash.pawl_released': 'PAWL RELEASED',
    'dash.pawl_engaged_sub': 'parking lock active',
    'dash.pawl_released_sub': 'mechanical lock disengaged',
    'dash.pawl_engaged_long': 'Parking pawl engaged',
    'dash.pawl_released_long': 'Parking pawl released',
    'dash.excellent': 'excellent',
    'dash.check': 'check',
    'dash.excellent_cap': 'Excellent',
    'dash.pack_extremes_loading': 'Pack extremes: loading…',
    'dash.pack_extremes': 'PACK EXTREMES (across {n} cells)',
    'dash.cell_n': 'cell #{n}',
    'dash.cell_dash': 'cell #—',
    'dash.modules_hdr': '{n} MODULES · MIN..MAX mV · TEMP',
    'dash.no_temp': 'no temp',
    'dash.find_hint': 'Settings → Find adapter',
    'dash.good': 'good',
    'dash.fair': 'fair',
    'dash.good_cap': 'Good',
    'dash.fair_cap': 'Fair',
    'dash.poor_cap': 'Poor',
    'dash.cells_title': 'Cells',
    'dash.range_s': 'Range',
    'dash.range_inline': 'Range ~{n} km',
    'dash.battery_s': 'Battery',
    'dash.odometer_s': 'Odometer',
    'dash.eta100': 'ETA to 100%',
    'dash.this_session_inline': 'This session: ',
    'dash.trip_live': 'Trip #{id} · LIVE',
    'dash.kwh_used': '{e} kWh used',
    'dash.consumption_s': 'Consumption',
    'dash.cells_balance': 'CELLS BALANCE',

    'cells.tab_balance': 'Cells balance',
    'cells.tab_thermal': 'Thermal',
    'cells.empty': 'No data. Connect to the car.',
    'cells.balance_fmt': 'Balance: {q}',
    'cells.even': ' — even',
    'cells.normal': ' — normal',
    'cells.uneven': ' — uneven',
    'cells.check_cooling': ' — check cooling',
    'cells.spread_d': 'SPREAD Δ',
    'cells.modules_hdr': '{m} MODULES · {c} CELLS TOTAL',
    'cells.no_temp_sensor': 'no temp sensor',
    // v0.1.29+102: HAL cumulative balance (BMS min/max pair, dongle-free).
    'cells.hal_cumulative_note':
        'Pack minimum and maximum cell voltage.',
    'cells.min_v': 'Min',
    'cells.max_v': 'Max',
    'cells.pack_temp': 'Pack temp',
    // v0.1.29+108: honest BZ3 battery-state screen (dongle-free). Title no
    // longer promises a per-cell picture we can't deliver without a dongle.
    'cells.tab_state': 'Battery state',
    'cells.state_intro':
        'Live battery summary. Per-cell voltages need an adapter.',
    'cells.spread_bar': 'Cell voltage spread',
    'cells.soc': 'SOC',
    'cells.soh': 'SOH',

    'hist.title': 'History',
    'hist.hdr': 'HISTORY',
    'hist.tab_trips': 'Trips',
    'hist.tab_trends': 'Trends',
    'hist.empty_title': 'No trips yet',
    'hist.empty_hint': 'Connect the adapter and drive — '
        'history will fill in automatically.',
    'hist.active_fmt': 'ACTIVE · {dur}',
    'hist.active_trip': 'ACTIVE TRIP',
    'hist.distance': 'DISTANCE',
    'hist.energy': 'ENERGY',
    'hist.energy_used': 'ENERGY USED',
    'hist.avg_cons': 'AVG CONSUMPTION',
    'hist.peak_power': 'PEAK POWER',
    'hist.peak_kw': 'PEAK kW',
    'hist.time': 'TIME',
    'hist.dist': 'DIST',
    'hist.avg': 'AVG',
    'hist.temp': 'TEMP',
    'hist.max_temp_chip': 'max {t}°C',

    // ── trends ──
    'trends.empty_title': 'No trips in this period',
    'trends.empty_hint': 'Trends is built from completed trips. Take a drive '
        'with the adapter connected — totals, consumption and charts will '
        'appear here.',
    'trends.total_fmt': 'total {km} km · {n} trips',
    'trends.cost_total_fmt': 'total {c} {v} · {n} mo',
    'trends.avg_cons_fmt': 'avg {x} kWh/100km · {n} trips',
    'trends.avg_regen_fmt': 'avg {x}% · {n} trips',
    'trends.soh_fmt': 'was {a}% → now {b}% · {n} pts',
    'trends.sec_totals': 'Period totals',
    'trends.sec_cumulative': 'Cumulative',
    'trends.sec_efficiency': 'Driving efficiency',
    'trends.sec_health': 'Battery health',
    'trends.cumulative_dist': 'Cumulative distance',
    'trends.cumulative_dist_sub': 'km running total',
    'trends.km': 'km',
    'trends.cost_by_month': 'Cost by month',
    'trends.cost_by_month_sub': '{v} for energy',
    'trends.avg_cons': 'Avg consumption',
    'trends.kwh100': 'kWh/100km',
    'trends.regen_share': 'Regen share',
    'trends.regen_share_sub': '% of energy returned',
    'trends.soh_sub': '% capacity · slow degradation',
    // v0.1.31+130 (Trends v2): period bars + SOH combo + cell spread.
    'trends.cons_by_period': 'Consumption by period',
    'trends.cons_by_period_sub': 'kWh/100km · weighted average per bar',
    'trends.regen_by_period': 'Regen share by period',
    'trends.regen_by_period_sub': '% of energy returned per bar',
    'trends.cell_spread': 'Cell voltage spread',
    'trends.cell_spread_sub': 'max ΔmV per trip · lower is better',
    'trends.mv': 'mV',
    'trends.soh_combo_sub': 'dots = Ah method · line = BMS',
    'trends.soh_accumulating': 'Ah: accumulating · BMS: {c}%',
    'trends.soh_combo_fmt': 'Ah: {a}→{b}% ({n} est.) · BMS: {c}%',
    'trends.avg_cons_period_fmt': 'avg {x} kWh/100km',
    'trends.avg_regen_period_fmt': 'avg {x}% · {n} periods',
    'trends.est_range_fmt': '≈ {n} km per 100%',
    'trends.cell_spread_fmt': 'was {a} → now {b} mV · {n} trips',
    'trends.m_dist': 'Distance',
    'trends.m_energy': 'Energy',
    'trends.m_spent': 'Spent',
    'trends.m_regen': 'Regenerated',
    'trends.m_km_fmt': '{n} km',
    'trends.m_kwh_fmt': '{n} kWh',
    'trends.not_enough': '{n} point(s) — not enough for a chart',

    // ── trip detail ──
    'trip.title': 'Trip #{id}',
    'trip.soc_vs_time': 'SOC vs time',
    'trip.battery_temp': 'Battery temperature',
    'trip.pack_v_filtered': 'Pack voltage (filtered)',
    // v0.1.29+128: snapshot-fallback charts
    'trip.chart_src_snapshots': '· BMS snapshots (~1/min)',
    'trip.charging_power': 'Charging power',
    'trip.hv_bus_v': 'HV bus voltage',
    'trip.power_profile': 'Power / regen',
    'trip.traction': 'Traction',
    'trip.regen': 'Regen',
    'trip.regen_recovered': '⚡ {kwh} kWh recovered · peak {peak} kW',
    'trip.completed': 'COMPLETED',
    'trip.running_suffix': ' (running)',
    'trip.total_suffix': ' total',
    'trip.m_distance': 'Distance',
    'trip.m_energy_used': 'Energy used',
    'trip.m_total_cost': 'Total cost',
    'trip.m_avg_cons': 'Avg consumption',
    'trip.m_soc_range': 'SOC range during trip',
    'trip.m_temp_range': 'Battery temp range',
    'trip.m_cell_spread': 'Max cell spread',
    'trip.m_peak_speed': 'Peak speed',
    'trip.m_avg_moving': 'Avg moving speed',
    'trip.m_avg_speed': 'Avg speed',
    'trip.m_time_moving': 'Time moving / idle',
    'trip.m_energy_precise': 'Energy (precise SOC)',
    'trip.m_samples': 'Samples logged',
    'trip.metrics_hdr': 'TRIP METRICS',
    'trip.odometer_hdr': 'ODOMETER',
    'trip.time_breakdown': 'TIME BREAKDOWN',
    'trip.moving_fmt': 'Moving  {d}',
    'trip.idle_fmt': 'Idle    {d}',
    'trip.speed_dist': 'SPEED DISTRIBUTION',
    'trip.no_speed_data': 'No speed data for this trip',
    'trip.no_samples': 'No samples recorded for this trip at all\n'
        '(trip detection or polling was inactive)',
    'trip.all_idle': 'All samples were at 0 km/h (idle trip)',
    'trip.only_n_points': 'Only {n} point(s)',

    // ── diagnostics (DTC) ──
    'dtc.not_connected': 'Not connected. Connect the adapter in Settings.',
    'dtc.json_copied': 'JSON copied to clipboard',
    'dtc.title': 'Diagnostics (DTC)',
    'dtc.copy_json': 'Copy JSON',
    'dtc.scan_hdr': 'DTC SCAN',
    'dtc.scanning_cur': 'Scanning: {cur}',
    'dtc.last_scan': 'Last scan: {t}',
    'dtc.scan_desc': 'Read fault codes from 9 ECUs. Read-only.',
    'dtc.scanning': 'Scanning…',
    'dtc.run_again': 'Run again',
    'dtc.run_scan': 'Run scan',
    'dtc.progress': '{a} / {b} ECU',
    'dtc.active_found': '{n} active fault(s) found',
    'dtc.clean_no_active': 'Clean (no active faults)',
    'dtc.all_clean': 'All ECUs clean',
    'dtc.summary': '{e} ECU scanned · {a} active · {r} readiness · {i} with entries',
    'dtc.n_active': '{n} active fault(s)',
    'dtc.n_readiness': '{n} readiness flags',
    'dtc.probe_error': 'probe error',
    'dtc.clean': 'clean',
    'dtc.ext_session': 'Extended session not opened',
    'dtc.no_dtc': 'No DTCs',
    'dtc.tap_run': 'Tap "Run scan" to read DTCs',
    'dtc.scan_takes': 'A scan takes ~30 seconds. Polling is paused during '
        'the scan to keep BLE load down.',
    'dtc.flags_hdr': 'Status flags meaning:',
    'dtc.flag_active': 'Active fault — a real fault right now',
    'dtc.flag_readiness': 'Readiness — test not yet performed (not a fault)',

    // ── data & export ──
    'dataexp.sec_storage': 'STORAGE',
    'dataexp.sec_export': 'EXPORT',
    'dataexp.sec_cleanup': 'CLEANUP',
    'dataexp.counting': 'Counting…',
    'dataexp.export_intro': 'Builds a zip archive with all selected data and '
        'opens the system "Share" sheet. The file can be saved to a USB '
        'stick via the file manager, sent to cloud storage or a messenger.',
    'dataexp.trips_sub': 'trips.csv — opens in Excel/Numbers',
    'dataexp.snapshots_sub': 'snapshots.csv — data behind long-term charts',
    'dataexp.samples_sub': 'samples.sqlite — binary DB dump (compact), '
        'opens in DB Browser',
    'dataexp.livelogs_sub':
        'live_log_sessions.csv + live_log_entries.csv (time-series)',
    'dataexp.exporting': 'Exporting: {stage}...',
    'dataexp.share_btn': 'Share',
    'dataexp.save_btn': 'Save to Downloads',
    'dataexp.hu_note': 'On the head unit choose "Save to Downloads" — the '
        'file lands in the system Downloads folder, where the file manager '
        'can open it and copy it to a USB stick. On a phone "Share" is more '
        'convenient.',
    'dataexp.cleanup_warn': 'Deletion is irreversible. Export your data '
        'before clearing.',
    'dataexp.clear_samples': 'Clear raw samples',
    'dataexp.clear_samples_sub': 'Delete all detailed measurements (DID history)',
    'dataexp.clear_samples_q': 'Delete all raw samples?',
    'dataexp.clear_samples_desc': 'Trips and Snapshots stay, but detailed '
        'measurements will be lost. This is the largest table.',
    'dataexp.n_samples_deleted': '{n} samples deleted',
    'dataexp.clear_snapshots': 'Clear snapshots',
    'dataexp.clear_snapshots_sub': 'Empties the long-term charts (Trends)',
    'dataexp.clear_snapshots_q': 'Delete all snapshots?',
    'dataexp.clear_snapshots_desc': 'Trends charts (24h / 7d / 30d / 1y / '
        'all) will be empty. Data starts accumulating again within 2-10 '
        'minutes.',
    'dataexp.n_snapshots_deleted': '{n} snapshots deleted',
    'dataexp.clear_trips': 'Clear all trips',
    'dataexp.clear_trips_sub': 'Deletes trips + linked samples (cascade)',
    'dataexp.clear_trips_q': 'Delete all trips and samples?',
    'dataexp.clear_trips_desc': 'Trip history and all measurements inside '
        'them will be lost. Snapshots stay.',
    'dataexp.trips_samples_deleted': '{t} trips and {s} samples deleted',
    'dataexp.clear_sweeps': 'Clear sweep results',
    'dataexp.clear_sweeps_sub': 'Deletes the logs of all DID scans',
    'dataexp.clear_sweeps_q': 'Delete all sweep results?',
    'dataexp.clear_sweeps_desc': 'In-car DID scan history will be lost. '
        'Useful when sweep results take a lot of space.',
    'dataexp.runs_results_deleted': '{r} runs and {s} results deleted',
    'dataexp.clear_livelogs': 'Clear Live Log sessions',
    'dataexp.clear_livelogs_sub': 'Deletes all time-series recordings',
    'dataexp.clear_livelogs_q': 'Delete all Live Log sessions?',
    'dataexp.clear_livelogs_desc': 'Time-series polling history will be '
        'lost. Export your data before clearing.',
    'dataexp.sessions_entries_deleted': '{a} sessions and {b} entries deleted',
    'dataexp.saved_fmt': 'Saved ({size}): {summary}\nPath: {path}',
    'dataexp.shared_fmt': 'Shared ({size}): {summary}',
    'dataexp.share_cancelled_fmt':
        'Archive created ({size}): {summary}. Share cancelled.',
    'dataexp.error_fmt': 'Error: {e}',
    'dataexp.export_failed_fmt': 'Export failed: {e}',
    'common.delete': 'Delete',

    // ── polling diagnostics ──
    'polld.title': 'Polling diagnostics',
    'polld.ok_reads': 'ok reads',
    'polld.getter_calls': 'getter calls',
    'polld.getter_nulls': 'getter nulls',
    'polld.null_rate': 'null rate',
    'polld.current_gap': 'current gap',
    'polld.max_gap': 'max gap',
    'polld.reset': 'Reset counters',
    'polld.how_to': 'How to read this:\n'
        '\u2022 If max gap stays under ~3000 ms, the 2-second stale-gate '
        'on packCurrentA is the proximate cause of any flicker — '
        'one cycle of bad luck is enough.\n'
        '\u2022 If max gap climbs into 10000+ ms, the transport is '
        'stalling for real (790-chain stall or BLE loss under '
        'burst load).\n'
        '\u2022 null rate reflects what the UI saw, not what came over '
        'the wire — high rate with low max gap means the UI is '
        'polling faster than the cycle refills the cache.',

    // ── research tools (Advanced) ──
    'raw.title': 'Raw Data',
    'raw.ecu_modules': 'ECU MODULES',
    'raw.dids_live': '{n} DIDs · live',
    'raw.no_data': 'No data. Polling has not reached this ECU yet,\nor it is not responding.',
    'raw.diag_hdr': 'DIAGNOSTICS',
    'raw.diag_can_run':
        'Run a DID sweep to capture raw responses for analysis. Available while parking.',
    'raw.diag_locked':
        'Locked while driving. Diagnostics sweep saturates BLE for several minutes — engage parking (gear = P) to enable.',
    'raw.run_sweep': 'Run sweep',
    'raw.coming_soon':
        'Diagnostics UI coming in next release. For now use bz5_scanner CLI on Mac.',
    'raw.ecu_bms_master': 'cells, SOC, pack stats',
    'raw.ecu_vcu': 'gear, odometer, parking',
    'raw.ecu_pdu': 'pack nominal const + PDU temps',
    'raw.ecu_obc': 'on-board charger',
    'raw.ecu_slave': 'sub-pack',
    'ecux.title': 'All ECUs (30)',

    // ── sweep / live log (Advanced) ──
    'sw.prev_runs': 'Previous sweep runs',
    'sw.in_progress': 'Sweep in progress',
    'sw.eta_fmt': 'ETA {t}',
    'sw.current_did': 'CURRENT DID',
    'sw.cancel': 'Cancel sweep',
    'sw.connect_hint': 'Connect to ELM327 via Settings → ELM327 BLE adapter.',
    'sw.busy_livelog': 'Live Log is currently running',
    'sw.busy_dtc': 'DTC scan is currently running',
    'sw.busy_sweep': 'DID Sweep is currently running',
    'sw.busy_note': 'Sweep will be available when the other operation finishes.',
    'sw.complete': 'Sweep complete',
    'sw.run_n': 'Run #{n}',
    'sw.open': 'Open',
    'sw.car_state': 'Car state (optional)',
    'sw.notes': 'Notes (optional)',
    'sw.start_custom': 'Start custom sweep',
    'sw.confirm_note': 'Normal polling will be paused during the sweep. '
        'Screen stays awake. Cancel anytime.',
    'sw.tx_rx_required': 'TX and RX are required',
    'sw.bad_range': 'Invalid DID range',
    'sw.start_failed': 'Failed to start sweep',
    'll.prev_sessions': 'Previous live-log sessions',
    'll.busy_note': '{r}. Live Log will be available when the other operation finishes.',
    'll.complete': 'Live log complete',
    'll.session_n': 'Session #{n}',
    'll.dids_hdr': 'DIDs to poll (up to 7)',
    'll.cycle_note': 'One cycle = one request to each DID in turn. With 5 '
        'DIDs a cycle is ~1.2 s (~0.8 Hz overall). Entries stream into the '
        'DB — cancelling loses no data.',
    'll.add_did': 'Add DID ({n}/7)',
    'll.annotations': 'Annotations',
    'll.car_state': 'Car state',
    'll.fill_all': 'Fill in all fields: TX, RX (3+ hex), DID (1-4 hex, padded automatically).',
    'll.recording': 'RECORDING — cycle {n}',
    'll.latest': 'LATEST VALUES',
    'll.no_data_yet': '(no data yet)',
    'll.start': 'Start Live Log',
    'll.start_failed': 'Failed to start live-log',
    'sw.history': 'Sweep history',
    'sw.no_runs': 'No sweep runs yet',
    'sw.no_runs_hint': 'Run a sweep from Settings → DID Sweep '
        'or from Raw Data → Run sweep on head unit.',
    'sw.share_run': 'Share this run',
    'sw.save_downloads': 'Save to Downloads',
    'sw.no_match': 'No results match filter',
    'sw.range_fmt': 'Range: 0x{a} .. 0x{b} ({n} DIDs)',
    'sw.valid_fmt': '{v} valid · {e} no response or error',
    'sw.car_state_fmt': 'Car state: {s}',
    'sw.notes_fmt': 'Notes: {s}',
    'sw.error_fmt': 'Error: {e}',
    'sw.saved_fmt': 'Saved: {p}',
    'sw.export_failed_fmt': 'Export failed: {e}',
    'll.history': 'Live Log history',
    'll.no_sessions': 'No live-log sessions yet',
    'll.no_sessions_hint': 'Run a session from Settings → Live Log.',
    'll.share_session': 'Share this session',
    'll.cycles_entries_fmt': '{c} cycles · {e} entries',
    'll.no_entries': 'No entries',
    'hist.temp_range': 'TEMP RANGE',
    'hist.soc_over_time': 'SOC over time',
    'hist.collecting': 'Collecting data…',
    'hist.battery_temp': 'Battery temp',
    'hist.pack_voltage': 'Pack voltage',

    'chg.power_hdr': 'CHARGING POWER',
    'chg.calc_note': 'Calculating… need ≥0.3% SOC growth to overcome '
        'quantization noise '
        '(~7 min at 2 kW AC, ~3 min at 7 kW AC, ~20 sec at 50 kW DC)',
    'chg.power_formula':
        'Power = ΔSOC × pack kWh / Δt, integrated over up to 10 min for accuracy',
    'chg.analyzing': 'analyzing…',
    'chg.cv_phase': 'CV phase (tapering)',
    'chg.almost_done': 'Almost done',
    'chg.phase': 'PHASE',
    'chg.gain_since': '+{n}% since plug-in',
    'chg.eta100': 'ETA TO 100%',
    'chg.need5': 'need ≥5 min of data',
    'chg.eta_note': 'linear extrapolation · curves to longer in CV',
    'chg.collecting': 'collecting… ({n} samples)',
    'chg.power': 'POWER',
    'chg.kw_vs_min': 'kW vs minutes',
    'chg.mv_vs_min_spread': 'mV vs min · current spread {s} mV',
    'chg.mv_vs_min': 'mV vs min',
    'chg.bat_temp': 'BATTERY TEMP',
    'chg.c_vs_min_now': '°C vs min · now {t} °C',
    'chg.c_vs_min': '°C vs min',
    'chg.charged': 'CHARGED',
    'chg.soc_gain': 'SOC GAIN',
    'chg.since_plugin': 'since plug-in',
    // v0.1.29+94: per-module UDS charge logger
    'chg.log.idle': 'Module charge log',
    'chg.log.active': 'Module charge log — RECORDING',
    'chg.log.hint': 'Start before plugging in (captures baseline + current onset)',
    'chg.log.stats': '{rows} rows · ~{pass}s per module pass',
    'chg.log.start': 'Start log',
    'chg.log.stop': 'Stop log',
    'chg.session': 'SESSION',
    'chg.session_sub': 'this charging session',
    'chg.counter_raw': 'raw — for scale calibration',
    'chg.lt1min': '<1 min',
    'chg.eta_m': '~{m} min',
    'chg.dur_m': '{m} min',
    'chg.dur_hm': '{h}h {m}m',
    'chg.banner': 'Charging • {detail}',
    'chg.starting': 'starting…',
    'chg.session_title': 'Charging session',
    'chg.session_ended': 'Charging session ended',
    // ── v0.1.29+100: Status screen (car_status provider) ──
    'status.title': 'Status',
    'status.subtitle': 'Vehicle health, service, fluids',
    'status.refresh': 'Refresh',
    'status.platform.header': 'Platform',
    'status.platform.engine': 'Engine',
    'status.platform.auto': 'auto-detected',
    'status.platform.override': 'manual override',
    'status.platform.unknown': 'Unrecognised DiLink',
    'status.loading': 'Loading…',
    'status.unavailable': 'Service data unavailable',
    'status.unavailable_sub':
        'The vehicle status provider could not be read on this device.',
    'status.health.ok': 'No errors',
    'status.health.ok_sub': 'no active faults',
    'status.health.fault': 'Faults present',
    'status.health.fault_sub': 'active faults: {n}',
    'status.health.unknown': 'Status unknown',
    'status.health.unknown_sub': 'no health signal',
    'status.service.header': 'Service',
    'status.service.remaining': 'to next service',
    'status.service.remaining_unknown': 'odometer needed for estimate',
    'status.service.threshold': 'service at',
    'status.service.odometer': 'odometer',
    'status.fluids.header': 'Fluids and tyres',
    'status.fluids.none': 'No fluid data reported',
    'status.fluids.note': '“OK” means the system flagged no problem.',
    'status.fluid.ok': 'OK',
    'status.fluid.attention': 'attention',
    'status.fluid.engine_oil': 'Engine oil',
    'status.fluid.at_fluid': 'Transmission fluid',
    'status.fluid.brake_fluid': 'Brake fluid',
    'status.fluid.battery_coolant': 'Battery coolant',
    'status.fluid.motor_coolant': 'Motor coolant',
    'status.fluid.tyre_pressure': 'Tyre pressure',
    'status.entry.title': 'Vehicle status',
    'status.entry.to_service': 'to service {km} km',
    'status.unit.km': 'km',
  };

  // ───────────────────────────── RU ─────────────────────────────
  static const Map<String, String> _ru = {
    // Common
    'common.cancel': 'Отмена',
    'common.save': 'Сохранить',
    'common.continue': 'Продолжить',
    'common.ok': 'OK',
    'common.close': 'Закрыть',
    'common.loading': 'Загрузка…',

    // Navigation — phone bottom bar
    'nav.dashboard': 'Дашборд',
    'nav.cells': 'Ячейки',
    'nav.history': 'История',
    'nav.settings': 'Настройки',
    // Navigation — head-unit rail
    'nav.driving': 'Вождение',
    'nav.vehicle': 'Автомобиль',

    // Relative time
    'rel.s_ago': '{n} с назад',
    'rel.m_ago': '{n} мин назад',
    'rel.h_ago': '{n} ч назад',
    'rel.d_ago': '{n} дн назад',

    // Settings — screen & sections
    'settings.title': 'Настройки',
    'settings.section.connection': 'Подключение',
    'settings.datasource.title': 'Откуда брать данные',
    'settings.datasource.subtitle': 'Откуда брать живые значения',
    'settings.datasource.auto': 'Авто (HAL, при сбое — OBD2)',
    'settings.datasource.hal': 'Из автомобиля',
    'settings.datasource.obd2': 'Через адаптер',
    'settings.datasource.hal_unavailable': 'Данные из автомобиля сейчас недоступны',
    'settings.datasource.hal_no_platform':
        'На этом устройстве доступен только адаптер',
    'datasource.hal_dead_hint':
        'HAL-стрим не идёт — Настройки → переключитесь на OBD2 или перезапустите приложение',
    'settings.section.cost': 'Стоимость',
    'settings.section.vehicle': 'Автомобиль',
    'settings.section.app': 'Приложение',
    'settings.section.language': 'Язык / Language',

    // Settings — connection
    'settings.adapter.not_connected': 'Не подключен',
    'settings.autoconnect.title': 'Автоподключение при запуске',
    'settings.autoconnect.subtitle':
        'Подключаться к запомненному адаптеру при запуске приложения',
    'settings.scan.busy': 'Поиск...',
    'settings.scan.start': 'Найти адаптер',
    'settings.scan.reconnect_last': 'Подключиться к последнему адаптеру',
    'settings.disconnect': 'Отключить',
    'settings.connected_snack': 'Подключено! Перейдите на Дашборд',
    // v0.1.29+110: локализованная плашка статуса (были enum-имена)
    'settings.conn.connected': 'Подключено',
    'settings.conn.connecting': 'Подключение…',
    'settings.conn.scanning': 'Поиск…',
    'settings.conn.error': 'Ошибка подключения',
    'settings.conn.disconnected': 'Не подключено',
    'settings.conn.adapter': 'Адаптер {addr}',
    'settings.device.unknown': 'Неизвестное устройство',
    // v0.1.29+110: пункт «Облачные сервисы» (О1) + 4 состояния строки
    'settings.cloud_services.title': 'Облачные сервисы',
    'cloud.menu.connected': 'Подключены',
    'cloud.menu.disconnected': 'Не подключены',
    'cloud.menu.auth_error': 'Ошибка входа',
    'cloud.menu.paused': 'На паузе',

    // About — hidden Advanced unlock (v0.1.29+59)
    'about.title': 'О приложении',
    'about.adv.progress': 'Ещё {n} тапов до Advanced',
    'about.adv.unlocked': 'Инструменты Advanced разблокированы — в Настройках',

    // Settings — cost
    'settings.cost.per_kwh.title': 'Стоимость 1 кВт·ч',
    'settings.cost.per_kwh.value': '{amount} за 1 кВт·ч',
    'settings.cost.per_kwh.unset':
        'Не настроено — стоимость поездки не показывается',
    'settings.cost.currency.title': 'Символ валюты',
    'settings.cost.currency.value': 'Текущий: "{symbol}" (пример: {example})',
    'dialog.cost.title': 'Стоимость 1 кВт·ч',
    'dialog.cost.label': 'Цена',
    'dialog.cost.hint': 'Например: 5.50',
    'dialog.cost.helper': 'В вашей валюте (символ — ниже в настройках). '
        '0 = выключить отображение стоимости.',
    'dialog.currency.title': 'Символ валюты',
    'dialog.currency.label': 'Символ',
    'dialog.currency.quick': 'Быстрый выбор:',

    // Settings — vehicle
    'settings.dtc.subtitle': 'Считать коды ошибок со всех ECU (только чтение)',
    'settings.about.title': 'О батарее / спецификация',
    'settings.about.subtitle':
        'Детали батареи BZ5, источники DID, эксперименты',

    // Settings — data
    'settings.data.title': 'Данные и экспорт',
    'settings.data.subtitle':
        'Экспорт trips/snapshots/samples на флешку или в облако, очистка',

    // Settings — advanced
    'settings.advanced.title': 'Расширенные',
    'settings.advanced.subtitle':
        'Инструменты исследования и диагностики приложения',
    'settings.rawdata.subtitle': 'Live DID таблица + diagnostics sweep (wide view)',
    'settings.ecu.subtitle': 'Реестр DID со всех ECU, live значения',
    'settings.sweep.subtitle': 'In-car ECU probe — presets и custom диапазоны',
    'settings.livelog.subtitle': 'Time-series polling до 7 DIDs одновременно',
    'settings.polldiag.subtitle': 'Счётчики чтения pack current, gaps, null rate',
    'settings.appdiag.title': 'Журнал приложения и синк',
    'settings.appdiag.subtitle':
        'Кольцевой буфер debugPrint + состояние CloudSync (dev)',
    'settings.hal.subtitle': 'Нативный BYD HAL — статус, подписки, логи',

    // App diagnostics screen (v0.1.29+122)
    'appdiag.title': 'Диагностика приложения',
    'appdiag.cloud.header': 'Состояние облачной синхронизации',
    'appdiag.log.header': 'Журнал приложения',
    'appdiag.copy': 'Копировать',
    'appdiag.export': 'Экспорт',
    'appdiag.clear': 'Очистить',
    'appdiag.copied': 'Журнал скопирован в буфер обмена',

    // Account (email OTP) — v0.1.29+124 (C2)
    'account.title': 'Аккаунт',
    'account.settings_subtitle': 'Вход по email, устройства и отзыв доступа',
    'account.intro': 'Войдите по email, чтобы управлять устройствами этого '
        'bridge-аккаунта. Вход доступен только адресам, разрешённым '
        'владельцем bridge.',
    'account.email_hint': 'Email',
    'account.send_code': 'Отправить код',
    'account.code_sent_neutral': 'Если адресу {email} разрешён вход — на '
        'него отправлен код (действует 10 минут). Проверьте и папку Спам. '
        'Из соображений безопасности экран не подтверждает, было ли письмо '
        'отправлено на самом деле.',
    'account.code_hint': 'Код из письма',
    'account.verify': 'Войти',
    'account.resend': 'Отправить снова',
    'account.resend_in': 'Повторно через',
    'account.resend_note': 'Новый код аннулирует предыдущий — работает '
        'только самый свежий.',
    'account.change_email': 'Другой email',
    'account.locked_for': 'Лимит запросов, подождите',
    'account.signed_in_as': 'Вход выполнен',
    'account.logout': 'Выйти',
    'account.devices_header': 'Устройства',
    'account.devices_empty': 'К аккаунту пока не привязано ни одного '
        'устройства.',
    'account.last_heartbeat': 'был на связи',
    'account.revoked': 'ОТОЗВАНО',
    'account.revoke': 'Отозвать',
    'account.revoke_confirm_title': 'Отозвать доступ устройства?',
    'account.revoke_confirm_body': '«{name}» потеряет доступ к облаку и '
        'перестанет синхронизироваться. Локальные данные на устройстве НЕ '
        'удаляются. Отменить из приложения нельзя.',
    'account.err_invalid_code': 'Код неверный, просроченный (10 минут) или '
        'уже использованный. После 5 ошибок код сгорает — запросите новый.',
    'account.err_not_allowed': 'Этому адресу вход не разрешён. Попросите '
        'владельца bridge добавить его в список разрешённых.',
    'account.err_rate_limited': 'Слишком много запросов — подождите и '
        'повторите (лимит: 5 кодов в час на адрес).',
    'account.err_not_configured': 'Аккаунты на этом bridge ещё не настроены '
        '(на сервере). Обратитесь к владельцу.',
    'account.err_session': 'Сессия завершена (повторное использование или '
        'истечение токена). Войдите заново.',
    'account.err_bad_email': 'Введите корректный email.',
    'account.err_network': 'Ошибка сети — проверьте соединение и повторите.',
    'account.err_generic': 'Запрос не выполнен',
    'account.claim_header': 'Привязать устройство',
    'account.claim_hint': 'На устройстве: Настройки → Привязка '
        'устройства → Получить код, затем введите этот код здесь.',
    'account.claim_code_hint': 'Код с устройства',
    'account.claim_button': 'Привязать',
    'account.claim_ok': 'Устройство привязано к аккаунту',
    'account.claim_invalid': 'Код неизвестен или истёк — получите новый '
        'на устройстве (действует 5 минут).',
    'account.claim_no_vehicle': 'У аккаунта нет автомобиля по умолчанию '
        '— обратитесь к владельцу bridge.',

    // Device pairing screen — v0.1.29+127 (C3)
    'pairing.title': 'Привязка устройства',
    'pairing.settings_subtitle': 'Привязать это устройство к аккаунту '
        '(код на экране → подтверждение на телефоне)',
    'pairing.intro_fresh': 'У этой установки ещё нет облачного доступа. '
        'Получите код, подтвердите его на залогиненном телефоне — токен '
        'выдастся автоматически и начнётся восстановление истории. Без '
        'ручного ввода токена.',
    'pairing.intro_live': 'Это устройство уже синхронизируется. '
        'Привязка прикрепит его к аккаунту — токен не меняется, данные '
        'не затрагиваются.',
    'pairing.kind_headunit': 'Головное устройство',
    'pairing.kind_phone': 'Телефон',
    'pairing.get_code': 'Получить код',
    'pairing.enter_on_phone': 'На залогиненном телефоне: Настройки → '
        'Облачные сервисы → Аккаунт → Привязать устройство — и введите '
        'этот код:',
    'pairing.expires_in': 'Код действует ещё',
    'pairing.paired_fresh': 'Привязано! Токен выдан — восстанавливаю '
        'историю…',
    'pairing.paired_live': 'Привязано! Устройство прикреплено к '
        'аккаунту.',
    'pairing.restore_status': 'Восстановление',
    'pairing.expired': 'Код истёк (5 минут). Получите новый.',
    'pairing.error': 'Привязка не удалась',
    'pairing.retry': 'Попробовать снова',
    'common.done': 'Готово',

    // Cloud backup card
    'cloud.title': 'Облачный бэкап',
    'cloud.intro': 'Сохраняет историю поездок и снимки BMS на bz5-bridge, '
        'чтобы они переживали переустановку головного устройства. '
        'Для настройки нужен токен от владельца bridge; для '
        'восстановления — client_token прежнего устройства.',
    'cloud.setup_btn': 'Настроить облачный бэкап',
    'cloud.restore_btn': 'Восстановить из облака',
    'cloud.enabled': 'Включено',
    'cloud.unknown_vehicle': '(неизвестный автомобиль)',
    'cloud.last_sync': 'Последняя синхронизация',
    'cloud.never': 'никогда',
    'cloud.pending': 'В очереди: {t} trips, {s} snapshots, {w} sweeps, '
        '{l} live-logs',
    'cloud.sync_now': 'Синхронизировать',
    'cloud.force_resync': 'Полный ресинк',
    'cloud.backup_token': 'Сохранить токен',
    'cloud.last_restore': 'Последнее восстановление',
    // Cloud status labels
    'cloud.status.not_set_up': 'Не настроено',
    'cloud.status.paused': 'Приостановлено',
    'cloud.status.up_to_date': 'Актуально',
    'cloud.status.caught_up': 'Синхронизировано, по расписанию',
    'cloud.status.syncing': 'Синхронизация…',
    'cloud.status.error': 'Ошибка — повтор',
    'cloud.status.auth_failed': 'Ошибка авторизации — нужна перерегистрация',
    // Restore progress lines (inline card)
    'cloud.restoring.validating': 'Восстановление: проверка токена…',
    'cloud.restoring.trips': 'Восстановление поездок: {a} новых / {b} получено',
    'cloud.restoring.snapshots':
        'Восстановление снимков: {a} новых / {b} получено (поездок: {c})',
    'cloud.restoring.generic': 'Восстановление…',

    // Cloud setup dialog
    'cloud.setup.title': 'Облачный бэкап — настройка',
    'cloud.setup.intro': 'Введите setup-токен от владельца bridge. '
        'Токен одноразовый: при повторной регистрации владелец '
        'должен будет выдать новый.',
    'cloud.setup.advanced': 'Дополнительно',
    'cloud.setup.failed': 'Ошибка настройки',
    'cloud.setup.no_vehicles.title': 'Нет автомобилей',
    'cloud.setup.no_vehicles.body':
        'На bridge не настроен ни один автомобиль. Попросите владельца добавить.',
    'cloud.setup.choose_vehicle': 'Выберите автомобиль',
    'cloud.setup.reg_failed': 'Ошибка регистрации',
    'cloud.setup.connected_snack':
        'Подключено к {name}. Первая синхронизация пройдёт в фоне.',

    // Force resync dialog
    'cloud.resync.title': 'Полный ресинк?',
    'cloud.resync.body':
        'Повторно выгружает все trips, snapshots, sweeps и live-logs '
        'из локальной БД. Bridge дедуплицирует — записи, уже '
        'существующие на сервере, не задвоятся. Полезно после '
        'восстановления Drift. Может занять несколько минут.',
    'cloud.resync.confirm': 'Ресинк',

    // Disconnect dialog
    'cloud.disconnect.title': 'Отключиться от bridge?',
    'cloud.disconnect.body':
        'Удаляет сохранённый client token. Локальные данные Drift '
        'не трогаются. Для повторного подключения понадобится '
        'новый setup-токен от владельца bridge.',
    'cloud.disconnect.confirm': 'Отключить',

    // Restore dialog
    'cloud.restore.title': 'Восстановление из облака',
    'cloud.restore.intro': 'Вставьте client_token прежнего устройства. Владелец '
        'bridge может посмотреть его на сервере; формат '
        '<device_id>.<secret>. Текущая облачная идентичность '
        'будет ЗАМЕНЕНА — выгрузка продолжится от имени '
        'восстановленного устройства.',
    'cloud.restore.rejected': 'Токен отклонён',
    'cloud.restore.replace.title': 'Заменить облачную идентичность?',
    'cloud.restore.replace.device': 'Устройство: {id}',
    'cloud.restore.replace.body': 'После подтверждения:\n'
        '  • текущий токен заменяется (текущая регистрация '
        'останется сиротой на сервере — попросите владельца '
        'отозвать при желании)\n'
        '  • trips + snapshots подтягиваются в локальный Drift '
        'с дедупликацией\n'
        '  • push-курсоры сдвигаются за максимальный локальный id, '
        'чтобы восстановленные строки не выгружались повторно',
    'cloud.restore.replace.warning':
        'Если на этой установке уже были поездки после '
        'переустановки приложения, эти локальные записи '
        'останутся в приложении, но НЕ будут выгружены '
        'под восстановленной идентичностью. (Чтобы избежать — '
        'восстанавливайтесь сразу после переустановки.)',
    'cloud.restore.replace.note':
        'Sweeps и live-log сессии в этой версии НЕ '
        'восстанавливаются — они доступны только через '
        'админ-инспекцию на bridge.',
    'cloud.restore.confirm': 'Восстановить',
    // Restore progress dialog
    'cloud.restore.hdr.validating': 'Проверка токена…',
    'cloud.restore.hdr.fetch_trips': 'Загрузка поездок…',
    'cloud.restore.hdr.fetch_snapshots': 'Загрузка снимков…',
    'cloud.restore.hdr.done': 'Восстановление завершено',
    'cloud.restore.hdr.cancelled': 'Восстановление отменено',
    'cloud.restore.hdr.error': 'Ошибка восстановления',
    'cloud.restore.hdr.finished': 'Восстановление закончено',
    'cloud.restore.line.trips': 'Поездки: {a} новых / {b} получено',
    'cloud.restore.line.snapshots': 'Снимки: {a} новых / {b} получено',
    'cloud.restore.done_snack': 'Восстановлено: {t} поездок, '
        '{s} снимков добавлено. Облачная синхронизация продолжена.',

    // Backup token dialog
    'cloud.token.none.title': 'Нет токена для сохранения',
    'cloud.token.none.body':
        'В защищённом хранилище нет активного client token. '
        'Сначала выполните настройку или восстановление.',
    'cloud.token.title': 'Сохранить client token',
    'cloud.token.intro': 'Сохраните этот токен в менеджере паролей. '
        'Сервер не может его восстановить (хранится sha256-хэш) — '
        'он понадобится для восстановления после переустановки '
        'на головном устройстве.',
    'cloud.token.length': 'Длина: {n} символов',
    'cloud.token.hide': 'Скрыть',
    'cloud.token.reveal': 'Показать',
    'cloud.token.copy': 'Копировать',
    'cloud.token.copied': 'Токен скопирован в буфер обмена',

    // Bridge diagnostic card
    'bridge.title': 'Bridge-диагностика',
    'bridge.intro': 'Позволяет владельцу bridge присылать диагностические '
        'команды на это устройство для sweep / live-log / native probe '
        'сессий. Использует ту же регистрацию, что и облачный бэкап '
        'выше — сначала настройте его. По умолчанию выключено.',
    'bridge.enable': 'Включить bridge-диагностику',
    'bridge.stats': 'Выполнено: {a}  ·  Отклонено: {b}',
    'bridge.last': 'Последняя: {kind} ({when})',
    'bridge.status.off': 'Выключено',
    'bridge.status.register_first': 'Сначала зарегистрируйтесь через облачный бэкап',
    'bridge.status.listening': 'Ожидание команд',
    'bridge.status.executing': 'Выполняется {kind}…',
    'bridge.status.error': 'Ошибка — повтор',
    'bridge.status.auth_failed':
        'Ошибка авторизации — перерегистрация через облачный бэкап',

    // ── v0.1.29+60: driver panels / dashboards ──
    'drv.speed': 'СКОРОСТЬ',
    'drv.soc': 'УРОВЕНЬ ЗАРЯДА',
    'drv.this_trip': 'ТЕКУЩАЯ ПОЕЗДКА',
    'drv.trip_cost': 'СТОИМОСТЬ',
    'drv.cell.distance': 'расстояние',
    'drv.cell.energy': 'энергия',
    'drv.cell.consumption': 'расход',
    'drv.cell.duration': 'длительность',
    'drv.cell.peak': 'макс. скорость',
    'drv.cell.avg_moving': 'средняя в движении',
    'drv.cell.avg_speed': 'средняя скорость',
    'drv.calculating': 'расчёт…',
    'drv.power': 'Мощность',
    'drv.regen': 'Рекуперация',
    'drv.odo': 'Пробег',
    'drv.cell_spread': 'Разброс',
    'drv.hal_extras': 'МОТОР',
    'drv.cell.trip_a': 'счётчик A',
    'drv.cell.trip_b': 'счётчик B',
    'drv.cell.motor_rpm': 'обороты',
    'drv.cell.motor_torque': 'момент',
    'drv.cell.motor_power': 'мощность мотора',
    'drv.cell.motor_temp': 'темп. мотора',
    'drv.cell.inverter_temp': 'темп. инвертора',
    'common.not_connected_title': 'Адаптер не подключен',
    'common.not_connected_hint': 'Перейдите в Настройки и нажмите «Найти адаптер»',
    'common.no_data': 'Нет данных',

    'dashw.pause_polling': 'Остановить опрос',
    'dashw.start_polling': 'Запустить опрос',
    'dash.range': 'ЗАПАС ХОДА',
    'dash.packv_live': 'НАПРЯЖЕНИЕ ПАКА (LIVE)',
    'dash.nominal': 'НОМИНАЛ',
    'dash.not_charging': 'Не заряжается',
    'dash.charging': 'ЗАРЯДКА',
    'dash.connected': 'Подключено',
    'dash.this_session': 'ЭТА СЕССИЯ',
    'dash.battery': 'БАТАРЕЯ',
    'dash.odometer': 'ПРОБЕГ',
    'dash.cycles': 'ЦИКЛЫ',
    'dash.total_energy': 'ЭНЕРГИЯ ВСЕГО',
    'dash.inverter': 'ИНВЕРТОР',
    'dash.pawl_engaged': 'ПАРКОВОЧНЫЙ ЗАМОК',
    'dash.pawl_released': 'ЗАМОК СНЯТ',
    'dash.pawl_engaged_sub': 'механический замок включён',
    'dash.pawl_released_sub': 'механический замок выключен',
    'dash.pawl_engaged_long': 'Парковочный замок включён',
    'dash.pawl_released_long': 'Парковочный замок снят',
    'dash.excellent': 'отлично',
    'dash.check': 'проверить',
    'dash.excellent_cap': 'Отлично',
    'dash.pack_extremes_loading': 'Экстремумы пака: загрузка…',
    'dash.pack_extremes': 'ЭКСТРЕМУМЫ ПАКА ({n} ячеек)',
    'dash.cell_n': 'ячейка #{n}',
    'dash.cell_dash': 'ячейка #—',
    'dash.modules_hdr': '{n} МОДУЛЕЙ · MIN..MAX mV · ТЕМП',
    'dash.no_temp': 'нет темп.',
    'dash.find_hint': 'Настройки → Найти адаптер',
    'dash.good': 'хорошо',
    'dash.fair': 'средне',
    'dash.good_cap': 'Хорошо',
    'dash.fair_cap': 'Средне',
    'dash.poor_cap': 'Плохо',
    'dash.cells_title': 'Ячейки',
    'dash.range_s': 'Запас',
    'dash.range_inline': 'Запас ~{n} km',
    'dash.battery_s': 'Батарея',
    'dash.odometer_s': 'Пробег',
    'dash.eta100': 'До 100%',
    'dash.this_session_inline': 'Эта сессия: ',
    'dash.trip_live': 'Поездка #{id} · LIVE',
    'dash.kwh_used': '{e} kWh израсходовано',
    'dash.consumption_s': 'Расход',
    'dash.cells_balance': 'БАЛАНС ЯЧЕЕК',

    'cells.tab_balance': 'Баланс ячеек',
    'cells.tab_thermal': 'Термо',
    'cells.empty': 'Нет данных. Подключитесь к автомобилю.',
    'cells.balance_fmt': 'Баланс: {q}',
    'cells.even': ' — равномерно',
    'cells.normal': ' — норма',
    'cells.uneven': ' — неравномерно',
    'cells.check_cooling': ' — проверь охлаждение',
    'cells.spread_d': 'РАЗБРОС Δ',
    'cells.modules_hdr': '{m} МОДУЛЕЙ · {c} ЯЧЕЕК ВСЕГО',
    'cells.no_temp_sensor': 'нет датчика темп.',
    // v0.1.29+102: HAL-кумулятив (пара min/max от BMS, без донгла).
    'cells.hal_cumulative_note':
        'Минимальное и максимальное напряжение ячейки в пакете.',
    'cells.min_v': 'Мин',
    'cells.max_v': 'Макс',
    'cells.pack_temp': 'Темп. пакета',
    // v0.1.29+108: честный экран состояния батареи на BZ3 (без донгла).
    'cells.tab_state': 'Состояние батареи',
    'cells.state_intro':
        'Сводка по батарее в реальном времени. Напряжения по ячейкам — нужен адаптер.',
    'cells.spread_bar': 'Разброс напряжений ячеек',
    'cells.soc': 'Заряд',
    'cells.soh': 'Здоровье',

    'hist.title': 'История',
    'hist.hdr': 'ИСТОРИЯ',
    'hist.tab_trips': 'Поездки',
    'hist.tab_trends': 'Тренды',
    'hist.empty_title': 'Поездок пока нет',
    'hist.empty_hint': 'Подключитесь к адаптеру и поезжайте — '
        'история начнёт заполняться автоматически.',
    'hist.active_fmt': 'АКТИВНА · {dur}',
    'hist.active_trip': 'АКТИВНАЯ ПОЕЗДКА',
    'hist.distance': 'РАССТОЯНИЕ',
    'hist.energy': 'ЭНЕРГИЯ',
    'hist.energy_used': 'ЭНЕРГИЯ',
    'hist.avg_cons': 'СРЕДНИЙ РАСХОД',
    'hist.peak_power': 'ПИК МОЩНОСТИ',
    'hist.peak_kw': 'ПИК kW',
    'hist.time': 'ВРЕМЯ',
    'hist.dist': 'ДИСТ',
    'hist.avg': 'СРЕДН',
    'hist.temp': 'ТЕМП',
    'hist.max_temp_chip': 'макс {t}°C',

    // ── trends ──
    'trends.empty_title': 'Нет поездок за этот период',
    'trends.empty_hint': 'Trends строится по завершённым поездкам. Сделайте '
        'поездку с подключённым адаптером — итоги, расход и графики появятся '
        'здесь.',
    'trends.total_fmt': 'итого {km} км · {n} поезд.',
    'trends.cost_total_fmt': 'итого {c} {v} · {n} мес',
    'trends.avg_cons_fmt': 'средн. {x} кВт·ч/100км · {n} поезд.',
    'trends.avg_regen_fmt': 'средн. {x}% · {n} поезд.',
    'trends.soh_fmt': 'было {a}% → сейчас {b}% · {n} точ.',
    'trends.sec_totals': 'Итоги за период',
    'trends.sec_cumulative': 'Накопительно',
    'trends.sec_efficiency': 'Эффективность вождения',
    'trends.sec_health': 'Здоровье батареи',
    'trends.cumulative_dist': 'Пробег накопительно',
    'trends.cumulative_dist_sub': 'км нарастающим итогом',
    'trends.km': 'км',
    'trends.cost_by_month': 'Затраты по месяцам',
    'trends.cost_by_month_sub': '{v} за энергию',
    'trends.avg_cons': 'Средний расход',
    'trends.kwh100': 'кВт·ч/100км',
    'trends.regen_share': 'Доля рекуперации',
    'trends.regen_share_sub': '% возвращённой энергии',
    'trends.soh_sub': '% ёмкости · медленная деградация',
    // v0.1.31+130 (Trends v2): периодные бары + SOH-комбо + разбаланс.
    'trends.cons_by_period': 'Расход по периодам',
    'trends.cons_by_period_sub': 'кВт·ч/100км · взвешенное среднее на бар',
    'trends.regen_by_period': 'Рекуперация по периодам',
    'trends.regen_by_period_sub': '% возвращённой энергии на бар',
    'trends.cell_spread': 'Разбаланс ячеек',
    'trends.cell_spread_sub': 'макс ΔмВ за поездку · меньше — лучше',
    'trends.mv': 'мВ',
    'trends.soh_combo_sub': 'точки = Ah-метод · линия = BMS',
    'trends.soh_accumulating': 'Ah: накапливается · BMS: {c}%',
    'trends.soh_combo_fmt': 'Ah: {a}→{b}% ({n} изм.) · BMS: {c}%',
    'trends.avg_cons_period_fmt': 'средн. {x} кВт·ч/100км',
    'trends.avg_regen_period_fmt': 'средн. {x}% · {n} период.',
    'trends.est_range_fmt': '≈ {n} км на 100%',
    'trends.cell_spread_fmt': 'было {a} → сейчас {b} мВ · {n} поезд.',
    'trends.m_dist': 'Пробег',
    'trends.m_energy': 'Энергия',
    'trends.m_spent': 'Потрачено',
    'trends.m_regen': 'Рекуперировано',
    'trends.m_km_fmt': '{n} км',
    'trends.m_kwh_fmt': '{n} кВт·ч',
    'trends.not_enough': '{n} точка — мало для графика',

    // ── trip detail ──
    'trip.title': 'Поездка #{id}',
    'trip.soc_vs_time': 'SOC во времени',
    'trip.battery_temp': 'Температура батареи',
    'trip.pack_v_filtered': 'Напряжение пака (фильтр.)',
    // v0.1.29+128: графики из снапшотов
    'trip.chart_src_snapshots': '· BMS-снапшоты (~1/мин)',
    'trip.charging_power': 'Мощность зарядки',
    'trip.hv_bus_v': 'Напряжение HV bus',
    'trip.power_profile': 'Мощность / реген',
    'trip.traction': 'Тяга',
    'trip.regen': 'Реген',
    'trip.regen_recovered': '⚡ {kwh} кВт·ч возвращено · пик {peak} кВт',
    'trip.completed': 'ЗАВЕРШЕНА',
    'trip.running_suffix': ' (идёт)',
    'trip.total_suffix': ' всего',
    'trip.m_distance': 'Расстояние',
    'trip.m_energy_used': 'Энергия',
    'trip.m_total_cost': 'Стоимость',
    'trip.m_avg_cons': 'Средний расход',
    'trip.m_soc_range': 'Диапазон SOC за поездку',
    'trip.m_temp_range': 'Диапазон темп. батареи',
    'trip.m_cell_spread': 'Макс. разброс ячеек',
    'trip.m_peak_speed': 'Макс. скорость',
    'trip.m_avg_moving': 'Средняя в движении',
    'trip.m_avg_speed': 'Средняя скорость',
    'trip.m_time_moving': 'Движение / простой',
    'trip.m_energy_precise': 'Энергия (точный SOC)',
    'trip.m_samples': 'Записано сэмплов',
    'trip.metrics_hdr': 'МЕТРИКИ ПОЕЗДКИ',
    'trip.odometer_hdr': 'ПРОБЕГ',
    'trip.time_breakdown': 'СТРУКТУРА ВРЕМЕНИ',
    'trip.moving_fmt': 'Движение  {d}',
    'trip.idle_fmt': 'Простой  {d}',
    'trip.speed_dist': 'РАСПРЕДЕЛЕНИЕ СКОРОСТИ',
    'trip.no_speed_data': 'Нет данных скорости за поездку',
    'trip.no_samples': 'Сэмплы за поездку не записаны вовсе\n'
        '(детект поездки или опрос были неактивны)',
    'trip.all_idle': 'Все сэмплы на 0 km/h (стоянка)',
    'trip.only_n_points': 'Только {n} точка(и)',

    // ── diagnostics (DTC) ──
    'dtc.not_connected': 'Не подключено. Подключите адаптер в Настройках.',
    'dtc.json_copied': 'JSON скопирован в буфер обмена',
    'dtc.title': 'Диагностика (DTC)',
    'dtc.copy_json': 'Копировать JSON',
    'dtc.scan_hdr': 'СКАН DTC',
    'dtc.scanning_cur': 'Сканирую: {cur}',
    'dtc.last_scan': 'Последний скан: {t}',
    'dtc.scan_desc': 'Считать коды ошибок с 9 ECU. Read-only.',
    'dtc.scanning': 'Сканирую…',
    'dtc.run_again': 'Повторить',
    'dtc.run_scan': 'Запустить скан',
    'dtc.progress': '{a} / {b} ECU',
    'dtc.active_found': 'Найдено активных ошибок: {n}',
    'dtc.clean_no_active': 'Чисто (активных ошибок нет)',
    'dtc.all_clean': 'Все ECU чистые',
    'dtc.summary': '{e} ECU просканировано · {a} активных · {r} readiness · {i} с записями',
    'dtc.n_active': '{n} активных ошибок',
    'dtc.n_readiness': '{n} readiness-флагов',
    'dtc.probe_error': 'ошибка пробы',
    'dtc.clean': 'чисто',
    'dtc.ext_session': 'Extended session не открыта',
    'dtc.no_dtc': 'Нет DTC',
    'dtc.tap_run': 'Нажмите «Запустить скан», чтобы считать DTC',
    'dtc.scan_takes': 'Сканирование занимает ~30 секунд. Polling '
        'приостанавливается на время скана, чтобы не нагружать BLE.',
    'dtc.flags_hdr': 'Значение статус-флагов:',
    'dtc.flag_active': 'Active fault — реальная ошибка прямо сейчас',
    'dtc.flag_readiness': 'Readiness — тест ещё не выполнен (не fault)',

    // ── data & export ──
    'dataexp.sec_storage': 'ХРАНИЛИЩЕ',
    'dataexp.sec_export': 'ЭКСПОРТ',
    'dataexp.sec_cleanup': 'ОЧИСТКА',
    'dataexp.counting': 'Подсчёт...',
    'dataexp.export_intro': 'Создаёт zip-архив со всеми выбранными данными и '
        'открывает системное меню "Поделиться". Можно сохранить файл через '
        '"Проводник" на флешку, отправить в облако или мессенджер.',
    'dataexp.trips_sub': 'trips.csv — открывается в Excel/Numbers',
    'dataexp.snapshots_sub': 'snapshots.csv — данные для долговременных графиков',
    'dataexp.samples_sub': 'samples.sqlite — бинарный дамп БД (компактно), '
        'открывается в DB Browser',
    'dataexp.livelogs_sub':
        'live_log_sessions.csv + live_log_entries.csv (time-series)',
    'dataexp.exporting': 'Экспорт: {stage}...',
    'dataexp.share_btn': 'Поделиться (Share)',
    'dataexp.save_btn': 'Сохранить в Downloads',
    'dataexp.hu_note': 'На головном устройстве выбирайте «Сохранить в '
        'Downloads» — файл появится в системной папке Downloads, откуда его '
        'можно открыть через «Проводник» и скопировать на флешку. На '
        'телефоне удобнее «Поделиться».',
    'dataexp.cleanup_warn': 'Удаление данных безвозвратно. Перед очисткой '
        'рекомендуем сделать экспорт.',
    'dataexp.clear_samples': 'Очистить raw samples',
    'dataexp.clear_samples_sub': 'Удалить все детальные measurements (история DID)',
    'dataexp.clear_samples_q': 'Удалить все raw samples?',
    'dataexp.clear_samples_desc': 'Trips и Snapshots сохранятся, но '
        'детальные measurements будут утеряны. Это самая объёмная таблица.',
    'dataexp.n_samples_deleted': '{n} samples удалено',
    'dataexp.clear_snapshots': 'Очистить snapshots',
    'dataexp.clear_snapshots_sub': 'Очистит долговременные графики (Trends)',
    'dataexp.clear_snapshots_q': 'Удалить все snapshots?',
    'dataexp.clear_snapshots_desc': 'Trends графики (24h / 7d / 30d / 1y / '
        'all) будут пустыми. Данные начнут накапливаться заново через 2-10 '
        'минут.',
    'dataexp.n_snapshots_deleted': '{n} snapshots удалено',
    'dataexp.clear_trips': 'Очистить все trips',
    'dataexp.clear_trips_sub': 'Удаляет trips + связанные samples (cascade)',
    'dataexp.clear_trips_q': 'Удалить все trips и samples?',
    'dataexp.clear_trips_desc': 'История поездок и все measurements в них '
        'будут утеряны. Snapshots останутся.',
    'dataexp.trips_samples_deleted': '{t} trips и {s} samples удалено',
    'dataexp.clear_sweeps': 'Очистить sweep results',
    'dataexp.clear_sweeps_sub': 'Удалит логи всех DID-сканирований',
    'dataexp.clear_sweeps_q': 'Удалить все sweep results?',
    'dataexp.clear_sweeps_desc': 'История in-car DID сканирований будет '
        'утеряна. Может быть полезно если sweep results занимают много места.',
    'dataexp.runs_results_deleted': '{r} runs и {s} results удалено',
    'dataexp.clear_livelogs': 'Очистить Live Log sessions',
    'dataexp.clear_livelogs_sub': 'Удалит все time-series записи',
    'dataexp.clear_livelogs_q': 'Удалить все Live Log sessions?',
    'dataexp.clear_livelogs_desc': 'История time-series polling будет '
        'утеряна. Перед очисткой рекомендуем экспортировать данные.',
    'dataexp.sessions_entries_deleted': '{a} sessions и {b} entries удалено',
    'dataexp.saved_fmt': 'Сохранено ({size}): {summary}\nПуть: {path}',
    'dataexp.shared_fmt': 'Поделено ({size}): {summary}',
    'dataexp.share_cancelled_fmt':
        'Архив создан ({size}): {summary}. Поделиться отменено.',
    'dataexp.error_fmt': 'Ошибка: {e}',
    'dataexp.export_failed_fmt': 'Экспорт не удался: {e}',
    'common.delete': 'Удалить',

    // ── polling diagnostics ──
    'polld.title': 'Диагностика опроса',
    'polld.ok_reads': 'успешных чтений',
    'polld.getter_calls': 'вызовов геттера',
    'polld.getter_nulls': 'null от геттера',
    'polld.null_rate': 'доля null',
    'polld.current_gap': 'текущий разрыв',
    'polld.max_gap': 'макс. разрыв',
    'polld.reset': 'Сбросить счётчики',
    'polld.how_to': 'Как это читать:\n'
        '\u2022 Если max gap держится ниже ~3000 ms, причина мерцаний — '
        '2-секундный stale-gate на packCurrentA: одного неудачного цикла '
        'достаточно.\n'
        '\u2022 Если max gap уходит в 10000+ ms — транспорт реально '
        'стопорится (стопор 790-цепочки или потеря BLE под burst-нагрузкой).\n'
        '\u2022 null rate отражает то, что видел UI, а не то, что пришло по '
        'проводу — высокий rate при низком max gap значит, что UI опрашивает '
        'быстрее, чем цикл наполняет кэш.',

    // ── research tools (Advanced) ──
    'raw.title': 'Raw Data',
    'raw.ecu_modules': 'МОДУЛИ ECU',
    'raw.dids_live': '{n} DIDs · live',
    'raw.no_data': 'Нет данных. Polling ещё не достиг этого ECU,\nили он не отвечает.',
    'raw.diag_hdr': 'ДИАГНОСТИКА',
    'raw.diag_can_run':
        'Запустить DID sweep для захвата raw-ответов на анализ. Доступно на парковке.',
    'raw.diag_locked':
        'Заблокировано в движении. Diagnostics sweep насыщает BLE на несколько минут — включите парковку (gear = P).',
    'raw.run_sweep': 'Запустить sweep',
    'raw.coming_soon':
        'UI диагностики появится в следующем релизе. Пока используйте bz5_scanner CLI на Mac.',
    'raw.ecu_bms_master': 'ячейки, SOC, статистика пака',
    'raw.ecu_vcu': 'передача, одометр, парковка',
    'raw.ecu_pdu': 'номиналы пака + температуры PDU',
    'raw.ecu_obc': 'бортовое зарядное',
    'raw.ecu_slave': 'суб-пак',
    'ecux.title': 'Все ECU (30)',

    // ── sweep / live log (Advanced) ──
    'sw.prev_runs': 'Предыдущие sweep-запуски',
    'sw.in_progress': 'Sweep выполняется',
    'sw.eta_fmt': 'ETA {t}',
    'sw.current_did': 'ТЕКУЩИЙ DID',
    'sw.cancel': 'Отменить sweep',
    'sw.connect_hint': 'Подключитесь к ELM327 через Настройки → ELM327 BLE adapter.',
    'sw.busy_livelog': 'Сейчас выполняется Live Log',
    'sw.busy_dtc': 'Сейчас выполняется DTC-скан',
    'sw.busy_sweep': 'Сейчас выполняется DID Sweep',
    'sw.busy_note': 'Sweep станет доступен после завершения другой операции.',
    'sw.complete': 'Sweep завершён',
    'sw.run_n': 'Запуск #{n}',
    'sw.open': 'Открыть',
    'sw.car_state': 'Состояние машины (опц.)',
    'sw.notes': 'Заметки (опц.)',
    'sw.start_custom': 'Запустить custom sweep',
    'sw.confirm_note': 'Обычный polling будет приостановлен на время sweep. '
        'Экран не погаснет. Можно отменить в любой момент.',
    'sw.tx_rx_required': 'TX и RX обязательны',
    'sw.bad_range': 'Некорректный диапазон DID',
    'sw.start_failed': 'Не удалось запустить sweep',
    'll.prev_sessions': 'Предыдущие live-log сессии',
    'll.busy_note': '{r}. Live Log станет доступен после завершения другой операции.',
    'll.complete': 'Live log завершён',
    'll.session_n': 'Сессия #{n}',
    'll.dids_hdr': 'DIDs для опроса (до 7)',
    'll.cycle_note': 'Один цикл = один запрос к каждому DID подряд. С 5 DIDs '
        'цикл ~1.2 сек (~0.8 Hz общая частота). Записи в БД stream-ом — '
        'отмена не потеряет данные.',
    'll.add_did': 'Добавить DID ({n}/7)',
    'll.annotations': 'Аннотации',
    'll.car_state': 'Состояние машины',
    'll.fill_all': 'Заполните все поля: TX, RX (3+ hex), DID (1-4 hex, padded автоматически).',
    'll.recording': 'ЗАПИСЬ — цикл {n}',
    'll.latest': 'ПОСЛЕДНИЕ ЗНАЧЕНИЯ',
    'll.no_data_yet': '(данных пока нет)',
    'll.start': 'Запустить Live Log',
    'll.start_failed': 'Не удалось запустить live-log',
    'sw.history': 'История sweep',
    'sw.no_runs': 'Sweep-запусков пока нет',
    'sw.no_runs_hint': 'Запустите sweep из Настройки → DID Sweep '
        'или из Raw Data → Run sweep на головном устройстве.',
    'sw.share_run': 'Поделиться запуском',
    'sw.save_downloads': 'Сохранить в Downloads',
    'sw.no_match': 'Нет результатов по фильтру',
    'sw.range_fmt': 'Диапазон: 0x{a} .. 0x{b} ({n} DIDs)',
    'sw.valid_fmt': '{v} валидных · {e} без ответа или ошибка',
    'sw.car_state_fmt': 'Состояние машины: {s}',
    'sw.notes_fmt': 'Заметки: {s}',
    'sw.error_fmt': 'Ошибка: {e}',
    'sw.saved_fmt': 'Сохранено: {p}',
    'sw.export_failed_fmt': 'Экспорт не удался: {e}',
    'll.history': 'История Live Log',
    'll.no_sessions': 'Live-log сессий пока нет',
    'll.no_sessions_hint': 'Запустите сессию из Настройки → Live Log.',
    'll.share_session': 'Поделиться сессией',
    'll.cycles_entries_fmt': '{c} циклов · {e} записей',
    'll.no_entries': 'Нет записей',
    'hist.temp_range': 'ДИАПАЗОН ТЕМП',
    'hist.soc_over_time': 'SOC во времени',
    'hist.collecting': 'Накопление данных...',
    'hist.battery_temp': 'Температура батареи',
    'hist.pack_voltage': 'Напряжение пака',

    'chg.power_hdr': 'МОЩНОСТЬ ЗАРЯДКИ',
    'chg.calc_note': 'Расчёт… нужен прирост SOC ≥0.3%, чтобы перекрыть '
        'шум квантования '
        '(~7 мин на 2 kW AC, ~3 мин на 7 kW AC, ~20 сек на 50 kW DC)',
    'chg.power_formula':
        'Мощность = ΔSOC × kWh пака / Δt, интегрируется до 10 мин для точности',
    'chg.analyzing': 'анализ…',
    'chg.cv_phase': 'CV фаза (затухание)',
    'chg.almost_done': 'Почти готово',
    'chg.phase': 'ФАЗА',
    'chg.gain_since': '+{n}% с подключения',
    'chg.eta100': 'ДО 100%',
    'chg.need5': 'нужно ≥5 минут данных',
    'chg.eta_note': 'линейная экстраполяция · в CV дольше',
    'chg.collecting': 'накопление… ({n} сэмплов)',
    'chg.power': 'МОЩНОСТЬ',
    'chg.kw_vs_min': 'kW по минутам',
    'chg.mv_vs_min_spread': 'mV по мин · разброс {s} mV',
    'chg.mv_vs_min': 'mV по мин',
    'chg.bat_temp': 'ТЕМП БАТАРЕИ',
    'chg.c_vs_min_now': '°C по мин · сейчас {t} °C',
    'chg.c_vs_min': '°C по мин',
    'chg.charged': 'ЗАРЯЖЕНО',
    'chg.soc_gain': 'ПРИРОСТ SOC',
    'chg.since_plugin': 'с момента plug-in',
    // v0.1.29+94: per-module UDS charge logger
    'chg.log.idle': 'Лог модулей на заряде',
    'chg.log.active': 'Лог модулей — ИДЁТ ЗАПИСЬ',
    'chg.log.hint': 'Запусти ДО втыкания (поймает baseline + старт тока)',
    'chg.log.stats': '{rows} строк · ~{pass}с на проход модулей',
    'chg.log.start': 'Старт лога',
    'chg.log.stop': 'Стоп лога',
    'chg.session': 'СЕССИЯ',
    'chg.session_sub': 'на текущей зарядке',
    'chg.counter_raw': 'raw — для калибровки scale',
    'chg.lt1min': '<1 мин',
    'chg.eta_m': '~{m} мин',
    'chg.dur_m': '{m} мин',
    'chg.dur_hm': '{h}ч {m}м',
    'chg.banner': 'Зарядка • {detail}',
    'chg.starting': 'запуск…',
    'chg.session_title': 'Сессия зарядки',
    'chg.session_ended': 'Зарядка завершена',
    // ── v0.1.29+100: экран Статус (провайдер car_status) ──
    'status.title': 'Статус',
    'status.subtitle': 'Состояние авто, ТО, жидкости',
    'status.refresh': 'Обновить',
    'status.platform.header': 'Платформа',
    'status.platform.engine': 'Движок',
    'status.platform.auto': 'определена автоматически',
    'status.platform.override': 'ручной выбор',
    'status.platform.unknown': 'Неизвестная DiLink',
    'status.loading': 'Загрузка…',
    'status.unavailable': 'Данные сервиса недоступны',
    'status.unavailable_sub':
        'Провайдер статуса автомобиля не прочитан на этом устройстве.',
    'status.health.ok': 'Нет ошибок',
    'status.health.ok_sub': 'активных неисправностей нет',
    'status.health.fault': 'Есть неисправности',
    'status.health.fault_sub': 'активных неисправностей: {n}',
    'status.health.unknown': 'Статус неизвестен',
    'status.health.unknown_sub': 'нет сигнала о состоянии',
    'status.service.header': 'ТО (обслуживание)',
    'status.service.remaining': 'до следующего ТО',
    'status.service.remaining_unknown': 'для оценки нужен одометр',
    'status.service.threshold': 'порог ТО',
    'status.service.odometer': 'одометр',
    'status.fluids.header': 'Жидкости и шины',
    'status.fluids.none': 'Нет данных по жидкостям',
    'status.fluids.note': '«В норме» = система не отметила проблем.',
    'status.fluid.ok': 'в норме',
    'status.fluid.attention': 'внимание',
    'status.fluid.engine_oil': 'Моторное масло',
    'status.fluid.at_fluid': 'Трансмиссионная',
    'status.fluid.brake_fluid': 'Тормозная',
    'status.fluid.battery_coolant': 'Охлаждайка батареи',
    'status.fluid.motor_coolant': 'Охлаждайка мотора',
    'status.fluid.tyre_pressure': 'Давление шин',
    'status.entry.title': 'Состояние авто',
    'status.entry.to_service': 'до ТО {km} км',
    'status.unit.km': 'км',
  };
}
