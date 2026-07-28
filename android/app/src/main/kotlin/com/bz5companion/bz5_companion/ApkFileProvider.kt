package com.bz5companion.bz5_companion

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File

/**
 * v0.1.73+172 — провайдер одного файла: подготовленного к установке APK.
 *
 * ЗАЧЕМ СВОЙ, А НЕ androidx FileProvider. Системному установщику нужно
 * ЧИТАТЬ файл, а он чужое приложение: `file://` c Android 7 запрещён
 * (FileUriExposedException), значит нужен `content://` от нас с
 * временным грантом.
 *
 * ПОПРАВКА v0.1.74+173. В +172 здесь стояло обоснование, ссылавшееся
 * на невозможность проверить наличие androidx.core в classpath. Оно
 * НЕВЕРНО, и проверка была доступна: `share_plus`, который стоит у нас
 * в pubspec, объявляет в своём манифесте провайдер
 * `ShareFileProvider : androidx.core.content.FileProvider`. Значит
 * androidx.core на compile- и runtime-classpath гарантированно, и
 * никакого риска сборки не было. Утверждение писалось по памяти и
 * выдавало догадку за факт — ровно то, из-за чего в манифесте с +155
 * полтора месяца простояла запись про «стену» boot-пути.
 *
 * Настоящая причина оставить свой провайдер — она же и достаточная:
 * штатный требует `res/xml` с описанием путей и обслуживает целые
 * каталоги, а нам нужен РОВНО ОДИН файл. Полсотни строк на голом
 * фреймворке отдают только его и ничего больше.
 *
 * Отдаёт РОВНО один файл — `cacheDir/staged_update.apk`. Путь из
 * запроса игнорируется намеренно: это не файловый сервер, и обходить
 * его каталогами (`../`) не через что.
 */
class ApkFileProvider : ContentProvider() {

    companion object {
        /** Имя в кэше. Совпадает с тем, что пишет ApkInstall.stage(). */
        const val STAGED = "staged_update.apk"

        const val MIME = "application/vnd.android.package-archive"

        /** Авторитет собирается от packageName — так же, как в
         *  манифесте через ${applicationId}. */
        fun authority(packageName: String) = "$packageName.apkprovider"
    }

    override fun onCreate(): Boolean = true

    override fun getType(uri: Uri): String = MIME

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val f = File(context!!.cacheDir, STAGED)
        return ParcelFileDescriptor.open(
            f, ParcelFileDescriptor.MODE_READ_ONLY
        )
    }

    /**
     * Установщик спрашивает имя и размер через OpenableColumns —
     * без них диалог показывает пустое место вместо названия пакета.
     */
    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor {
        val f = File(context!!.cacheDir, STAGED)
        val cols: Array<String> = projection?.map { it }?.toTypedArray()
            ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val row: List<Any?> = cols.map { c ->
            when (c) {
                OpenableColumns.DISPLAY_NAME -> STAGED
                OpenableColumns.SIZE -> f.length()
                else -> null
            }
        }
        return MatrixCursor(cols, 1).apply { addRow(row) }
    }

    // Только чтение. Писать сюда нечего и некому.
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(
        uri: Uri, selection: String?, selectionArgs: Array<out String>?
    ): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?
    ): Int = 0
}
