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
 * временным грантом. Штатное решение — `androidx.core.content
 * .FileProvider`, и оно потянуло бы androidx.core в compile-classpath.
 * Он там почти наверняка есть (эмбеддинг Flutter им пользуется), но
 * «почти» здесь означает провал сборки на CI и потерянный цикл, а
 * проверить локально нечем: Gradle в контейнере не запускается.
 * Собственный провайдер — полсотни строк на голом фреймворке, ноль
 * допущений, и заодно не нужен `res/xml` с путями.
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
