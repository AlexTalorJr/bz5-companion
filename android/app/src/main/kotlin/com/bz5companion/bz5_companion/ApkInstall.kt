package com.bz5companion.bz5_companion

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import java.io.File

/**
 * v0.1.73+172 — ПУТЬ УСТАНОВКИ: сначала прочитать, потом попробовать.
 *
 * ЗАЧЕМ. Обновиться на ГУ нечем. Штатный проводник APK не запускает,
 * ADB нет, а `SilentInstaller` на существующий пакет отвечает
 * `系统已安装` и засчитывает это себе в УСПЕХ — то есть установку он
 * даже не начинает: приложение, которое попробовало и не смогло, не
 * пишет себе успех. На телефоне тот же APK с той же подписью и тем же
 * versionCode встаёт поверх без вопросов, так что дело не в пакете.
 * Значит подбирать ключи к SilentInstaller бессмысленно, и остаётся
 * единственный путь — ставить самим.
 *
 * Ставка на это высокая: пока обновление идёт через удаление, КАЖДЫЙ
 * патч стирает prefs и Drift, а из облака не возвращаются
 * `samples`/`hal_samples` и недобранные полосы атласа. Установка
 * поверх сохранила бы всё.
 *
 * ПОЧЕМУ ДВЕ ЧАСТИ. `probe()` — только чтение, отвечает на вопрос
 * «есть ли на этой прошивке системный установщик вообще». Если его
 * вырезали, никакая наша кнопка не поможет, и это надо знать ДО того,
 * как строить скачивание из GitHub Releases. `stage()`+`launch()` —
 * собственно попытка. Обе части едут в одной сборке намеренно: проба
 * без попытки объяснит отказ, но не докажет успех, а попытка без
 * пробы в случае отказа не скажет почему. Один цикл установки должен
 * закрыть вопрос целиком.
 *
 * Ничего не скачивает. Сеть добавится отдельно и только если
 * выяснится, что до установщика дело доходит.
 *
 * ── v0.1.77+176 — ЧТО СКАЗАЛО ПОЛЕ И ЧТО ИЗ ЭТОГО СЛЕДУЕТ ──────────
 *
 * Пять прогонов 29.07 дали одинаковый ответ: системный установщик на
 * прошивке ЖИВ (`view_resolvers` и `install_resolvers` указывают на
 * `com.android.packageinstaller`), но `staged_bytes` во всех пяти равен
 * нулю. То есть до установщика дело не дошло НИ РАЗУ, и его ответ до
 * сих пор неизвестен. Обе стены стоят раньше:
 *
 *   1. ФАЙЛА НЕТ. `ACTION_OPEN_DOCUMENT` перехвачен галереей BYD
 *      (`com.byd.auto_photo/…ImageSelectActivity`), а она перечисляет
 *      только изображения и видео — отсюда `暂无图片或视频` на трёх
 *      фотографиях и `pick → cancelled`. Выбрать APK системным
 *      диалогом на этой прошивке нельзя в принципе.
 *   2. РАЗРЕШЕНИЯ НЕТ. `unknown_sources_resolvers` пуст,
 *      `ACTION_MANAGE_UNKNOWN_APP_SOURCES` бросает
 *      `ActivityNotFoundException`: экрана «установка из неизвестных
 *      источников» на прошивке не существует.
 *
 * Разрешение главнее файла: скачивание без него даёт файл, который
 * некому поставить. Поэтому здесь три ответа на первую стену и одна
 * широкая проба по второй, и ни один путь не объявлен обязательным —
 * каждый деградирует в следующий.
 *
 * ПОРЯДОК ПУТЕЙ К ФАЙЛУ, И ПОЧЕМУ ИМЕННО ТАКОЙ.
 *
 *   A1a. SAF-ДЕРЕВО — первым. `ACTION_OPEN_DOCUMENT_TREE` и
 *        `StorageVolume.createOpenDocumentTreeIntent()` это ДРУГОЕ
 *        действие, чем захваченный галереей `ACTION_OPEN_DOCUMENT`,
 *        поэтому её фильтр его перехватывать не обязан. Владелец один
 *        раз отдаёт том флешки, `takePersistableUriPermission`
 *        переживает перезагрузку, дальше обход дерева идёт через
 *        `DocumentsContract` без единого разрешения на хранилище. На
 *        API 30+ для съёмных томов это единственный путь, который
 *        ЗАДУМАН работать.
 *   A1b. `MANAGE_EXTERNAL_STORAGE` — вторым, потому что его экран
 *        может отсутствовать точно так же, как отсутствует
 *        unknown-sources.
 *   A1c. `READ_EXTERNAL_STORAGE` — третьим и ТОЛЬКО как проба.
 *        `targetSdk` у нас 35 (проверено в `flutter.groovy` тега
 *        3.27.4, CI это нигде не переопределяет), поэтому
 *        `requestLegacyExternalStorage` не действует, а при
 *        `targetSdk ≥ 30` на устройстве API 32 это разрешение открывает
 *        только МЕДИА через scoped storage. APK не медиа — значит путь
 *        имеет структурный потолок и открыться не может. Пробируем всё
 *        равно: правило «ни один путь не предполагать» уже дважды
 *        оказывалось дороже, чем лишние двадцать строк. Побочная выгода
 *        — тем же прогоном проверяется, оживают ли публичные Downloads,
 *        мёртвые с +166.
 *
 * `target_sdk` и `version_code` теперь приезжают ИЗ ПОЛЯ, а не из моего
 * чтения gradle: первое превращает структурное рассуждение выше в
 * измеренное число, второе нужно §B, чтобы отказать в откате версии до
 * скачивания, а не после.
 */
object ApkInstall {

    const val CHANNEL = "bz5/apkinstall"

    /** Код запроса SAF-выбора файла. */
    const val REQ_PICK = 4171

    /** Код запроса SAF-выбора ДЕРЕВА (тома флешки). Отдельный от
     *  REQ_PICK: ответы приходят в одну точку, и различать их надо. */
    const val REQ_TREE = 4172

    /** Код запроса самой установки. Через startActivityForResult, а не
     *  startActivity, ровно за одним: чтобы получить resultCode. Пять
     *  прогонов 29.07 не дали ответа установщика вообще, и догадка
     *  «наверное, отказал по appop» стоит здесь ещё одного цикла. */
    const val REQ_INSTALL = 4173

    /** Имя двери, которой нет среди строк Settings: интент собирается
     *  у тома, а не у константы. */
    const val DOOR_CREATE_TREE = "StorageVolume.createOpenDocumentTreeIntent"

    private const val MIME = ApkFileProvider.MIME

    // ── часть 1: проба ────────────────────────────────────────────

    /**
     * Только чтение. Ни одного побочного действия — можно звать
     * сколько угодно и на телефоне тоже.
     *
     * ВАЖНО про видимость пакетов: с Android 11 `queryIntentActivities`
     * и `getPackageInfo` фильтруются, и без блока `<queries>` в
     * манифесте проба вернула бы пусто при полностью живом
     * установщике — то есть соврала бы в самую опасную сторону. Мы на
     * этом уже обжигались в +100: `ContentResolver` отдавал null для
     * провайдера carserver ровно по той же причине.
     */
    fun probe(context: Context): Map<String, Any?> {
        val pm = context.packageManager
        val out = LinkedHashMap<String, Any?>()
        out["sdk"] = Build.VERSION.SDK_INT
        out["package"] = context.packageName
        out["authority"] = ApkFileProvider.authority(context.packageName)
        out["can_request_installs"] =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                pm.canRequestPackageInstalls()
            } else {
                true
            }
        val dummy = Uri.parse(
            "content://${ApkFileProvider.authority(context.packageName)}/" +
                ApkFileProvider.STAGED
        )
        out["view_resolvers"] = resolvers(
            context,
            Intent(Intent.ACTION_VIEW).setDataAndType(dummy, MIME)
        )
        @Suppress("DEPRECATION")
        out["install_resolvers"] = resolvers(
            context,
            Intent(Intent.ACTION_INSTALL_PACKAGE).setDataAndType(dummy, MIME)
        )
        out["open_document_resolvers"] = resolvers(
            context,
            Intent(Intent.ACTION_OPEN_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType("*/*")
        )
        out["unknown_sources_resolvers"] =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                resolvers(
                    context,
                    Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                        .setData(Uri.parse("package:${context.packageName}"))
                )
            } else {
                emptyList<String>()
            }
        out["installer_packages"] = listOf(
            "com.android.packageinstaller",
            "com.google.android.packageinstaller",
            "com.android.permissioncontroller"
        ).filter { installed(context, it) }
        // ── +176: то, чего в пробе +172 не было ──────────────────
        //
        // targetSdk и versionCode ИЗ ПОЛЯ. Первое закрывает вопрос,
        // который до сих пор решался чтением gradle-скриптов: при
        // targetSdk ≥ 30 READ_EXTERNAL_STORAGE открывает только медиа,
        // и путь A1c имеет структурный потолок. Второе нужно §B, чтобы
        // отказать в откате версии ДО скачивания.
        out["target_sdk"] = try {
            context.applicationInfo.targetSdkVersion
        } catch (t: Throwable) {
            -1
        }
        out["version_code"] = try {
            @Suppress("DEPRECATION")
            context.packageManager
                .getPackageInfo(context.packageName, 0).versionCode
        } catch (t: Throwable) {
            -1
        }
        // Дерево — ПЕРВЫЙ путь, поэтому его резолверы читаются отдельно
        // от ACTION_OPEN_DOCUMENT: это разные действия, и захват
        // галереей BYD одного не означает захвата другого.
        out["tree_doc_resolvers"] = resolvers(
            context, Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        )
        out["get_content_resolvers"] = resolvers(
            context,
            Intent(Intent.ACTION_GET_CONTENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType("*/*")
        )
        out["send_resolvers"] = resolvers(
            context, Intent(Intent.ACTION_SEND).setType(MIME)
        )
        // Все двери к разрешению — одним списком, чтобы ни одна не
        // потерялась молча. Резолвится каждая; пустой список у двери
        // означает, что её на прошивке нет, и это ответ, а не сбой.
        val doorMap = LinkedHashMap<String, Any?>()
        for ((name, intent) in doorIntents(context)) {
            doorMap[name] = resolvers(context, intent)
        }
        out["doors"] = doorMap
        // Состояние обоих разрешений на хранилище. Ни одно из них не
        // является условием работы обзора — см. listApks.
        out["has_manage_all_files"] =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                try {
                    Environment.isExternalStorageManager()
                } catch (t: Throwable) {
                    false
                }
            } else {
                false
            }
        out["read_storage_granted"] = try {
            context.checkSelfPermission(
                android.Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
        } catch (t: Throwable) {
            false
        }
        // Отданные нам деревья переживают перезагрузку — если здесь
        // непусто, флешку больше просить не нужно.
        out["persisted_trees"] = persistedTrees(context)
        out["volumes"] = volumeReport(context)
        val staged = File(context.cacheDir, ApkFileProvider.STAGED)
        out["staged_bytes"] = if (staged.exists()) staged.length() else 0L
        return out
    }

    /**
     * Все двери к разрешению на установку и к файлу, одним списком.
     *
     * Список, а не набор вызовов по месту: гейт BL3 проверяет, что ни
     * одна дверь не потерялась, а сделать это можно только если они
     * перечислены в одном месте. Порядок значим — он же порядок показа
     * владельцу.
     *
     * Ни одна дверь не предполагается существующей. На этой прошивке
     * нет ни unknown-sources, ни DocumentsUI; единственный способ
     * узнать про остальные — спросить систему.
     */
    fun doorIntents(context: Context): List<Pair<String, Intent>> {
        val pkg = Uri.parse("package:${context.packageName}")
        val doors = ArrayList<Pair<String, Intent>>()
        // Дерево первым: это ответ на первую стену, и он же
        // единственный, который на API 30+ задуман работать.
        doors.add(
            Intent.ACTION_OPEN_DOCUMENT_TREE to
                Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        )
        val volumeTree = createTreeIntent(context)
        if (volumeTree != null) {
            doors.add(DOOR_CREATE_TREE to volumeTree)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            doors.add(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES to
                    Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                        .setData(pkg)
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Список вместо страницы одного приложения: страницы у нас
            // нет (поле 29.07), список — другой экран.
            doors.add(
                Settings.ACTION_MANAGE_ALL_UNKNOWN_APP_SOURCES to
                    Intent(Settings.ACTION_MANAGE_ALL_UNKNOWN_APP_SOURCES)
            )
            doors.add(
                Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION to
                    Intent(
                        Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION
                    ).setData(pkg)
            )
        }
        doors.add(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS to
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(pkg)
        )
        doors.add(
            Settings.ACTION_SECURITY_SETTINGS to
                Intent(Settings.ACTION_SECURITY_SETTINGS)
        )
        doors.add(
            Settings.ACTION_MANAGE_APPLICATIONS_SETTINGS to
                Intent(Settings.ACTION_MANAGE_APPLICATIONS_SETTINGS)
        )
        doors.add(
            Intent.ACTION_GET_CONTENT to
                Intent(Intent.ACTION_GET_CONTENT)
                    .addCategory(Intent.CATEGORY_OPENABLE)
                    .setType("*/*")
        )
        return doors
    }

    /** Интент дерева, собранный у СЪЁМНОГО тома. API 29+. null, если
     *  тома нет или прошивка не даёт его собрать. */
    private fun createTreeIntent(context: Context): Intent? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return try {
            val sm = context.getSystemService(Context.STORAGE_SERVICE)
                as StorageManager
            val vol = sm.storageVolumes.firstOrNull {
                it.isRemovable && it.state == Environment.MEDIA_MOUNTED
            } ?: sm.storageVolumes.firstOrNull { it.isRemovable }
            vol?.createOpenDocumentTreeIntent()
        } catch (t: Throwable) {
            null
        }
    }

    /** Деревья, которые владелец уже отдал. Гранты персистентные, то
     *  есть переживают перезагрузку — второй раз просить не нужно. */
    fun persistedTrees(context: Context): List<String> = try {
        context.contentResolver.persistedUriPermissions
            .filter { it.isReadPermission }
            .map { it.uri.toString() }
    } catch (t: Throwable) {
        emptyList()
    }

    /** Тома как их видит система. Перечисление прав НЕ требует —
     *  требует только чтение файлов внутри. */
    private fun volumeReport(context: Context): List<Map<String, Any?>> = try {
        val sm = context.getSystemService(Context.STORAGE_SERVICE)
            as StorageManager
        sm.storageVolumes.map { v ->
            val dir = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                v.directory?.absolutePath
            } else {
                null
            }
            mapOf<String, Any?>(
                "removable" to v.isRemovable,
                "primary" to v.isPrimary,
                "state" to v.state,
                "dir" to dir
            )
        }
    } catch (t: Throwable) {
        emptyList()
    }

    private fun resolvers(context: Context, intent: Intent): List<String> = try {
        @Suppress("DEPRECATION")
        context.packageManager.queryIntentActivities(intent, 0)
            .map { "${it.activityInfo.packageName}/${it.activityInfo.name}" }
    } catch (t: Throwable) {
        listOf("ERR ${t.javaClass.simpleName}")
    }

    private fun installed(context: Context, pkg: String): Boolean = try {
        @Suppress("DEPRECATION")
        context.packageManager.getPackageInfo(pkg, 0)
        true
    } catch (t: Throwable) {
        false
    }

    // ── часть 2: попытка ──────────────────────────────────────────

    /** Системный выбор файла. SAF намеренно: он не требует прав на
     *  хранилище (которые на этой прошивке слетают после каждой
     *  переустановки — открытый пункт +166) и видит подключённую
     *  флешку через DocumentsUI. */
    fun pick(activity: Activity) {
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
        // Не сужаем тип до APK-мимотипа: часть провайдеров не
        // проставляет его файлам с флешки, и фильтр показал бы пустой
        // список при живом файле.
        activity.startActivityForResult(i, REQ_PICK)
    }

    /** Копия выбранного файла в наш кэш — установщику отдаём своё,
     *  чужой content-Uri мы переуступить не можем. */
    fun stage(context: Context, uriStr: String): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        val dst = File(context.cacheDir, ApkFileProvider.STAGED)
        try {
            val uri = Uri.parse(uriStr)
            out["source_name"] = displayName(context, uri)
            val input = context.contentResolver.openInputStream(uri)
            if (input == null) {
                out["ok"] = false
                out["error"] = "openInputStream returned null"
                return out
            }
            input.use { ins -> dst.outputStream().use { ins.copyTo(it) } }
            out["ok"] = true
            out["bytes"] = dst.length()
        } catch (t: Throwable) {
            out["ok"] = false
            out["error"] = "${t.javaClass.simpleName}: ${t.message}"
        }
        return out
    }

    private fun displayName(context: Context, uri: Uri): String = try {
        context.contentResolver.query(
            uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null
        )?.use { c ->
            if (c.moveToFirst()) c.getString(0) ?: "?" else "?"
        } ?: "?"
    } catch (t: Throwable) {
        "?"
    }

    // ── часть 3 (+176): свой обозреватель APK ─────────────────────

    /**
     * Спросить у владельца ТОМ, а не файл.
     *
     * Пробуется сначала интент, собранный у самого съёмного тома
     * (`StorageVolume.createOpenDocumentTreeIntent`, API 29+), затем
     * общий `ACTION_OPEN_DOCUMENT_TREE`. Оба — ДРУГОЕ действие, чем
     * захваченный галереей BYD `ACTION_OPEN_DOCUMENT`, поэтому её
     * фильтр их перехватывать не обязан.
     *
     * Возвращает пошаговый отчёт: какой из двух интентов пошёл.
     */
    fun openTree(activity: Activity): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        val steps = ArrayList<String>()
        out["steps"] = steps
        val tries = ArrayList<Pair<String, Intent>>()
        val fromVolume = createTreeIntent(activity)
        if (fromVolume != null) {
            tries.add(DOOR_CREATE_TREE to fromVolume)
        } else {
            steps.add("$DOOR_CREATE_TREE → тома нет либо API < 29")
        }
        tries.add(
            Intent.ACTION_OPEN_DOCUMENT_TREE to
                Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        )
        for ((name, intent) in tries) {
            try {
                activity.startActivityForResult(intent, REQ_TREE)
                steps.add("$name → запущен")
                out["ok"] = true
                out["via"] = name
                return out
            } catch (t: Throwable) {
                steps.add("$name → ${t.javaClass.simpleName}: ${t.message}")
            }
        }
        out["ok"] = false
        return out
    }

    /**
     * Закрепить отданное дерево за нами.
     *
     * Без `takePersistableUriPermission` грант умирает вместе с
     * процессом, и владельцу пришлось бы отдавать флешку заново после
     * каждого пробуждения ГУ — то есть ровно в том сценарии, ради
     * которого всё это и делается.
     */
    fun rememberTree(context: Context, treeUri: String): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        return try {
            context.contentResolver.takePersistableUriPermission(
                Uri.parse(treeUri),
                Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
            out["ok"] = true
            out["trees"] = persistedTrees(context)
            out
        } catch (t: Throwable) {
            out["ok"] = false
            out["error"] = "${t.javaClass.simpleName}: ${t.message}"
            out
        }
    }

    /**
     * Найти APK всеми путями, какие открыты.
     *
     * КАЖДЫЙ ПУТЬ ДЕГРАДИРУЕТ, НИ ОДИН НЕ ЯВЛЯЕТСЯ УСЛОВИЕМ. Это не
     * стилистика: `MANAGE_EXTERNAL_STORAGE` требует экрана, которого на
     * этой прошивке может не быть — так же, как не оказалось экрана
     * unknown-sources. Сделай его обязательным, и обозреватель умрёт
     * целиком там, где SAF-дерево работало бы.
     *
     * Обход дерева идёт через `DocumentsContract` на голом фреймворке, а
     * не через `androidx.documentfile`: этой зависимости в проекте нет,
     * а добавлять её ради обхода в двадцать строк значит проверять на CI
     * то, что можно не проверять.
     *
     * Оба обхода ОГРАНИЧЕНЫ по ширине и глубине. На флешке может лежать
     * что угодно, включая чужую файловую свалку, и неограниченный
     * рекурсивный обход на главном потоке — тот же класс отказа, что
     * `readText()` многомегабайтного журнала.
     */
    fun listApks(context: Context): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        val notes = ArrayList<String>()
        val found = ArrayList<Map<String, Any?>>()

        // путь A1a — SAF-дерево. Прав на хранилище не требует вообще.
        val trees = persistedTrees(context)
        if (trees.isEmpty()) {
            notes.add("saf: дерево не отдано — «Указать флешку»")
        }
        for (t in trees) {
            try {
                val n = found.size
                found.addAll(scanTree(context, t))
                notes.add("saf: $t → ${found.size - n} APK")
            } catch (e: Throwable) {
                notes.add("saf: $t → ${e.javaClass.simpleName}: ${e.message}")
            }
        }

        // путь A1b/A1c — File API. Работает, только если одно из двух
        // разрешений выдано; отсутствие обоих — не ошибка, а ответ.
        try {
            val n = found.size
            found.addAll(scanFiles(context, notes))
            notes.add("file: ${found.size - n} APK")
        } catch (e: Throwable) {
            notes.add("file: ${e.javaClass.simpleName}: ${e.message}")
        }

        out["ok"] = found.isNotEmpty()
        out["apks"] = found
        out["notes"] = notes
        return out
    }

    /** Максимум каталогов, которые обходим на дереве, и файлов, которые
     *  показываем. Границы, а не оптимизация: см. докстринг listApks. */
    private const val TREE_DIR_BUDGET = 64
    private const val APK_LIMIT = 60

    private fun scanTree(
        context: Context, treeUri: String
    ): List<Map<String, Any?>> {
        val res = ArrayList<Map<String, Any?>>()
        val tree = Uri.parse(treeUri)
        val queue = ArrayList<String>()
        queue.add(DocumentsContract.getTreeDocumentId(tree))
        var dirs = 0
        var head = 0
        while (head < queue.size && dirs < TREE_DIR_BUDGET &&
            res.size < APK_LIMIT
        ) {
            val docId = queue[head]
            head++
            dirs++
            val children = DocumentsContract
                .buildChildDocumentsUriUsingTree(tree, docId)
            context.contentResolver.query(
                children,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                    DocumentsContract.Document.COLUMN_SIZE
                ),
                null, null, null
            )?.use { c ->
                while (c.moveToNext() && res.size < APK_LIMIT) {
                    val id = c.getString(0) ?: continue
                    val name = c.getString(1) ?: ""
                    val mime = c.getString(2) ?: ""
                    val size = if (c.isNull(3)) 0L else c.getLong(3)
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        queue.add(id)
                    } else if (name.endsWith(".apk", ignoreCase = true)) {
                        res.add(
                            mapOf(
                                "name" to name,
                                "bytes" to size,
                                "uri" to DocumentsContract
                                    .buildDocumentUriUsingTree(tree, id)
                                    .toString(),
                                "src" to "saf"
                            )
                        )
                    }
                }
            }
        }
        return res
    }

    private fun scanFiles(
        context: Context, notes: MutableList<String>
    ): List<Map<String, Any?>> {
        val res = ArrayList<Map<String, Any?>>()
        val manage =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                try {
                    Environment.isExternalStorageManager()
                } catch (t: Throwable) {
                    false
                }
            } else {
                false
            }
        val read = try {
            context.checkSelfPermission(
                android.Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
        } catch (t: Throwable) {
            false
        }
        if (!manage && !read) {
            notes.add("file: ни одного разрешения на хранилище — пропуск")
            return res
        }
        notes.add("file: manage=$manage read=$read")
        val roots = ArrayList<File>()
        try {
            val sm = context.getSystemService(Context.STORAGE_SERVICE)
                as StorageManager
            for (v in sm.storageVolumes) {
                val dir =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        v.directory
                    } else {
                        null
                    }
                if (dir != null) roots.add(dir)
            }
        } catch (t: Throwable) {
            notes.add("file: тома не перечислены: ${t.javaClass.simpleName}")
        }
        if (roots.isEmpty()) {
            @Suppress("DEPRECATION")
            roots.add(Environment.getExternalStorageDirectory())
        }
        for (r in roots) {
            for (dir in listOf(r, File(r, "Download"))) {
                val kids = try {
                    dir.listFiles()
                } catch (t: Throwable) {
                    null
                } ?: continue
                for (f in kids) {
                    if (res.size >= APK_LIMIT) return res
                    if (f.isFile && f.name.endsWith(".apk", true)) {
                        res.add(
                            mapOf(
                                "name" to f.name,
                                "bytes" to f.length(),
                                "uri" to Uri.fromFile(f).toString(),
                                "src" to "file"
                            )
                        )
                    }
                }
            }
        }
        return res
    }

    /**
     * Открыть названную дверь.
     *
     * Одна точка на все двери из `doorIntents`: развилка по месту
     * означала бы, что список и попытка расходятся, а список тут —
     * предмет гейта.
     */
    fun openDoor(activity: Activity, name: String): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        out["door"] = name
        val intent = doorIntents(activity).firstOrNull { it.first == name }
            ?.second
        if (intent == null) {
            out["ok"] = false
            out["error"] = "дверь не объявлена на этом API"
            return out
        }
        return try {
            if (name == Intent.ACTION_OPEN_DOCUMENT_TREE ||
                name == DOOR_CREATE_TREE
            ) {
                activity.startActivityForResult(intent, REQ_TREE)
            } else {
                activity.startActivity(intent)
            }
            out["ok"] = true
            out
        } catch (t: Throwable) {
            out["ok"] = false
            out["error"] = "${t.javaClass.simpleName}: ${t.message}"
            out
        }
    }

    /**
     * Отдать подготовленный файл системному установщику.
     *
     * Два действия подряд, и это не перестраховка: ACTION_VIEW —
     * современный путь, ACTION_INSTALL_PACKAGE — устаревший, но на
     * части OEM-прошивок зарегистрирован именно он. Стоит вторая
     * попытка пять строк, а цена незаданного вопроса — целый цикл
     * установки, который здесь стоит стирания всех данных.
     *
     * v0.1.77+176 — ПОПЫТКА ТЕПЕРЬ ЗАПИСЫВАЕТ ОТВЕТ ЦЕЛИКОМ, и ради
     * этого сменились две вещи.
     *
     *   1. `startActivityForResult` вместо `startActivity`. Пять
     *      прогонов 29.07 закончились `staged_bytes: 0` — установщик не
     *      пробовался ни разу, и его ответ до сих пор НЕИЗВЕСТЕН. Это
     *      главный неизвестный факт всей темы, и получить его можно
     *      только попросив систему вернуть resultCode.
     *   2. `FLAG_ACTIVITY_NEW_TASK` СНЯТ. С ним результат не
     *      возвращается: активити уходит в отдельную задачу, и наш
     *      `onActivityResult` не позовут никогда. Оставить флаг и ждать
     *      ответа значило бы построить прибор, который молчит по
     *      конструкции.
     *
     * Попытка идёт БЕЗ appop сознательно (`can_request_installs`
     * пишется в отчёт как было на момент попытки): возможно, установщик
     * сам предложит выдать разрешение. Мы этого не знаем, а узнать
     * можно только попробовав — экрана, который выдал бы appop заранее,
     * на прошивке нет.
     *
     * Возвращает пошаговый отчёт: в поле `steps` видно, что именно
     * пробовали и чем ответила система. resultCode дописывается позже,
     * из `onActivityResult` — синхронно его взять негде.
     */
    fun launch(activity: Activity): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        val steps = ArrayList<String>()
        out["steps"] = steps
        out["can_request_installs_at_attempt"] =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                try {
                    activity.packageManager.canRequestPackageInstalls()
                } catch (t: Throwable) {
                    false
                }
            } else {
                true
            }
        val staged = File(activity.cacheDir, ApkFileProvider.STAGED)
        if (!staged.exists() || staged.length() == 0L) {
            out["ok"] = false
            steps.add("staged file missing — выберите APK сначала")
            return out
        }
        out["staged_bytes"] = staged.length()
        val uri = Uri.parse(
            "content://${ApkFileProvider.authority(activity.packageName)}/" +
                ApkFileProvider.STAGED
        )
        @Suppress("DEPRECATION")
        for (action in listOf(
            Intent.ACTION_VIEW, Intent.ACTION_INSTALL_PACKAGE
        )) {
            try {
                val i = Intent(action)
                    .setDataAndType(uri, MIME)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                activity.startActivityForResult(i, REQ_INSTALL)
                steps.add("$action → запущен, ждём resultCode")
                out["ok"] = true
                out["action"] = action
                return out
            } catch (t: Throwable) {
                steps.add("$action → ${t.javaClass.simpleName}: ${t.message}")
                out["exception"] = "${t.javaClass.simpleName}: ${t.message}"
            }
        }
        out["ok"] = false
        return out
    }

    /** Экран «установка из неизвестных источников» для нашего пакета.
     *  Без этого разрешения установщик откажет молча, а само оно
     *  выдаётся только руками. */
    fun openUnknownSources(activity: Activity): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            out["ok"] = true
            out["note"] = "pre-O: разрешение не требуется"
            return out
        }
        return try {
            activity.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                    .setData(Uri.parse("package:${activity.packageName}"))
            )
            out["ok"] = true
            out
        } catch (t: Throwable) {
            out["ok"] = false
            out["error"] = "${t.javaClass.simpleName}: ${t.message}"
            out
        }
    }
}

/**
 * v0.1.77+176 — §A2: ПРИЁМ ФАЙЛА ЧЕРЕЗ «ПОДЕЛИТЬСЯ».
 *
 * Если штатный проводник умеет «поделиться», файл придёт к нам без
 * всякого выбора — то есть в обход первой стены (`ACTION_OPEN_DOCUMENT`
 * захвачен галереей BYD, которая перечисляет только изображения и
 * видео). Путь дешёвый и совершенно независимый от остальных трёх.
 *
 * ОТДЕЛЬНАЯ АКТИВИТИ, А НЕ ФИЛЬТР НА `MainActivity`. У главной активити
 * `taskAffinity=""` и `launchMode="singleTop"`; менять её поверхность
 * запуска ради приёма файла — риск, несоразмерный выгоде: она же
 * лончер, и поломка здесь стоит доступа к приложению целиком. Эта
 * стажирует и немедленно закрывается, своего UI у неё нет вообще.
 *
 * ПОЧЕМУ КЛАСС ЛЕЖИТ В ЭТОМ ФАЙЛЕ, А НЕ В СВОЁМ. Правило проекта: не
 * создавать новые `.kt` через `git format-patch` — в recon это восемь
 * раз дало silent class-drop с неустановленной причиной. Kotlin не
 * требует совпадения имени файла с именем класса, а дописать класс в
 * существующий файл — обычный хунк, который таким образом не теряется.
 */
class StageActivity : android.app.Activity() {
    override fun onCreate(saved: android.os.Bundle?) {
        super.onCreate(saved)
        val uri: Uri? = when (intent?.action) {
            Intent.ACTION_SEND ->
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
            Intent.ACTION_VIEW -> intent.data
            else -> null
        }
        if (uri == null) {
            AutostartMarker.write(this, "stage-share: no uri in intent")
            finish()
            return
        }
        // КОПИЯ ИДЁТ В РАБОЧЕМ ПОТОКЕ. APK это десятки мегабайт, и
        // читаются они с флешки, у которой скорость чтения
        // непредсказуема. Копировать столько в onCreate значит держать
        // главный поток на всё время копирования — а у этой активити
        // нет даже окна, в котором система показала бы, что она жива:
        // тема NoDisplay, владелец видит только зависший проводник,
        // из которого он поделился файлом.
        //
        // Активити живёт до конца копирования сознательно. Закройся она
        // раньше — процесс стал бы фоновым и мог быть снят посреди
        // записи, оставив в кэше огрызок под именем staged_update.apk.
        // Такой огрызок установщик возьмёт и отвергнет, а отказ
        // прочитается как «путь не работает».
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        Thread {
            val res = ApkInstall.stage(this, uri.toString())
            // Итог виден в журнале автозапуска: своего UI у активити
            // нет, а приложение в этот момент может быть не запущено
            // вовсе, и сказать владельцу результат больше негде. Журнал
            // уезжает диаг-дампом (+174) — каналом, который доехал
            // целым оба раза, когда экспортный ZIP приезжал обрезанным.
            AutostartMarker.write(
                this,
                "stage-share: ok=${res["ok"]} bytes=${res["bytes"] ?: 0}" +
                    " name=${res["source_name"] ?: "?"}" +
                    " err=${res["error"] ?: "-"}"
            )
            main.post { finish() }
        }.start()
    }
}
