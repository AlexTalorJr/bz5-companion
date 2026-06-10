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
    'settings.section.cost': 'Cost',
    'settings.section.cloud': 'Cloud',
    'settings.section.vehicle': 'Vehicle',
    'settings.section.language': 'Язык / Language',
    'settings.section.data': 'Data',

    // Settings — connection
    'settings.adapter.title': 'ELM327 BLE adapter',
    'settings.adapter.not_connected': 'Not connected',
    'settings.autoconnect.title': 'Auto-connect at startup',
    'settings.autoconnect.subtitle':
        'Connect to the remembered adapter when the app starts',
    'settings.speedmatch.title': 'Speed match speedometer (+5%)',
    'settings.speedmatch.subtitle':
        'Show speed as on the stock instrument cluster '
        '(per UN R39 it reads ~5% above true speed)',
    'settings.scan.busy': 'Scanning…',
    'settings.scan.start': 'Find adapter',
    'settings.scan.reconnect_last': 'Reconnect to last adapter',
    'settings.disconnect': 'Disconnect',
    'settings.connected_snack': 'Connected! Switch to Dashboard',

    // Settings — language (v0.1.29+59: System mode removed — explicit
    // EN default / RU switch only)
    'settings.language.ru': 'Русский',
    'settings.language.en': 'English',

    // About — hidden Advanced unlock (v0.1.29+59)
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
    'settings.hal.subtitle': 'Native BYD HAL probe — status, subscriptions, logs',

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
    'settings.section.cost': 'Стоимость',
    'settings.section.cloud': 'Облако',
    'settings.section.vehicle': 'Автомобиль',
    'settings.section.language': 'Язык / Language',
    'settings.section.data': 'Данные',

    // Settings — connection
    'settings.adapter.not_connected': 'Не подключен',
    'settings.autoconnect.title': 'Автоподключение при запуске',
    'settings.autoconnect.subtitle':
        'Подключаться к запомненному адаптеру при запуске приложения',
    'settings.speedmatch.title': 'Скорость как на приборке (+5%)',
    'settings.speedmatch.subtitle':
        'Показывать скорость как на штатной приборке '
        '(приборка по закону UN R39 завышает на ~5%)',
    'settings.scan.busy': 'Поиск...',
    'settings.scan.start': 'Найти адаптер',
    'settings.scan.reconnect_last': 'Подключиться к последнему адаптеру',
    'settings.disconnect': 'Отключить',
    'settings.connected_snack': 'Подключено! Перейдите на Дашборд',

    // About — hidden Advanced unlock (v0.1.29+59)
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
    'settings.dtc.subtitle': 'Считать коды ошибок со всех ECU (read-only)',
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
    'settings.hal.subtitle': 'Нативный BYD HAL — статус, подписки, логи',

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
  };
}
