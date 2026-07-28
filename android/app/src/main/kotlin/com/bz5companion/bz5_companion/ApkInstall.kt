package com.bz5companion.bz5_companion

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
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
 */
object ApkInstall {

    const val CHANNEL = "bz5/apkinstall"

    /** Код запроса SAF-выбора файла. */
    const val REQ_PICK = 4171

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
        val staged = File(context.cacheDir, ApkFileProvider.STAGED)
        out["staged_bytes"] = if (staged.exists()) staged.length() else 0L
        return out
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

    /**
     * Отдать подготовленный файл системному установщику.
     *
     * Два действия подряд, и это не перестраховка: ACTION_VIEW —
     * современный путь, ACTION_INSTALL_PACKAGE — устаревший, но на
     * части OEM-прошивок зарегистрирован именно он. Стоит вторая
     * попытка пять строк, а цена незаданного вопроса — целый цикл
     * установки, который здесь стоит стирания всех данных.
     *
     * Возвращает пошаговый отчёт: в поле `steps` видно, что именно
     * пробовали и чем ответила система.
     */
    fun launch(context: Context): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        val steps = ArrayList<String>()
        out["steps"] = steps
        val staged = File(context.cacheDir, ApkFileProvider.STAGED)
        if (!staged.exists() || staged.length() == 0L) {
            out["ok"] = false
            steps.add("staged file missing — выберите APK сначала")
            return out
        }
        val uri = Uri.parse(
            "content://${ApkFileProvider.authority(context.packageName)}/" +
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
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(i)
                steps.add("$action → запущен")
                out["ok"] = true
                out["action"] = action
                return out
            } catch (t: Throwable) {
                steps.add("$action → ${t.javaClass.simpleName}: ${t.message}")
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
