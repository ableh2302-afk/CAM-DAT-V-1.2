package com.ableh.dokumentasibarangpecah

import android.content.ClipData
import android.content.ContentValues
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Matrix
import android.graphics.Rect
import android.media.ExifInterface
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.zip.Deflater
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.concurrent.thread
import kotlin.math.abs
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val channel = "dokumentasi_barang_pecah/media_store"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveImage" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val name = call.argument<String>("displayName") ?: "foto.jpg"
                    val relative = call.argument<String>("relativePath") ?: "Pictures/Dokumentasi Barang Pecah"
                    if (bytes == null) {
                        result.error("NO_BYTES", "Data foto kosong", null)
                    } else {
                        try {
                            saveToGallery(bytes, name, relative)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SAVE_FAILED", e.message, null)
                        }
                    }
                }
                // Potong sesuai rasio layar + simpan, semuanya native (cepat) di thread latar belakang.
                "processPhoto" -> {
                    val src = call.argument<String>("src")
                    val dest = call.argument<String>("dest")
                    val name = call.argument<String>("displayName")
                    val relative = call.argument<String>("relativePath") ?: "Pictures/Dokumentasi Barang Pecah"
                    val ratio = call.argument<Double>("ratio") ?: 0.0
                    if (src == null || dest == null || name == null) {
                        result.error("BAD_ARGS", "Argumen tidak lengkap", null)
                    } else {
                        thread {
                            try {
                                val bytes = cropToJpeg(src, ratio)
                                FileOutputStream(File(dest)).use { it.write(bytes) }
                                try {
                                    saveToGallery(bytes, name, relative)
                                } catch (_: Exception) {
                                    // File lokal tetap tersimpan walau Galeri gagal.
                                }
                                runOnUiThread { result.success(true) }
                            } catch (e: Throwable) {
                                runOnUiThread { result.error("PROCESS_FAILED", e.message, null) }
                            }
                        }
                    }
                }
                "shareFiles" -> {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    val mime = call.argument<String>("mime") ?: "image/*"
                    try {
                        if (paths.isEmpty()) throw IllegalStateException("Tidak ada file")
                        val uris = ArrayList<Uri>()
                        for (p in paths) {
                            uris.add(FileProvider.getUriForFile(this, "$packageName.fileprovider", File(p)))
                        }
                        val intent = if (uris.size == 1) {
                            Intent(Intent.ACTION_SEND).apply { putExtra(Intent.EXTRA_STREAM, uris[0]) }
                        } else {
                            Intent(Intent.ACTION_SEND_MULTIPLE).apply { putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris) }
                        }
                        intent.type = mime
                        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        val clip = ClipData.newRawUri("Cam Dat", uris[0])
                        for (i in 1 until uris.size) clip.addItem(ClipData.Item(uris[i]))
                        intent.clipData = clip
                        startActivity(Intent.createChooser(intent, "Bagikan"))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SHARE_FAILED", e.message, null)
                    }
                }
                "zipFiles" -> {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    val zipName = call.argument<String>("zipName") ?: "CamDat.zip"
                    thread {
                        try {
                            cacheDir.listFiles()?.forEach { if (it.name.endsWith(".zip")) it.delete() }
                            val zipFile = File(cacheDir, zipName)
                            val used = HashSet<String>()
                            ZipOutputStream(FileOutputStream(zipFile).buffered()).use { zos ->
                                zos.setLevel(Deflater.BEST_SPEED)
                                for (p in paths) {
                                    val f = File(p)
                                    if (!f.exists()) continue
                                    var entry = f.name
                                    var n = 1
                                    while (!used.add(entry)) {
                                        entry = f.nameWithoutExtension + "_" + n + "." + f.extension
                                        n++
                                    }
                                    zos.putNextEntry(ZipEntry(entry))
                                    f.inputStream().use { it.copyTo(zos) }
                                    zos.closeEntry()
                                }
                            }
                            runOnUiThread { result.success(zipFile.absolutePath) }
                        } catch (e: Throwable) {
                            runOnUiThread { result.error("ZIP_FAILED", e.message, null) }
                        }
                    }
                }
                "deleteGallery" -> {
                    val names = call.argument<List<String>>("names") ?: emptyList()
                    val relative = call.argument<String>("relativePath") ?: "Pictures/Dokumentasi Barang Pecah"
                    thread {
                        var count = 0
                        for (name in names) {
                            try {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                    count += contentResolver.delete(
                                        MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                                        MediaStore.Images.Media.DISPLAY_NAME + "=? AND " + MediaStore.Images.Media.RELATIVE_PATH + " LIKE ?",
                                        arrayOf(name, "$relative%")
                                    )
                                } else {
                                    val pictures = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
                                    val f = File(File(pictures, relative.removePrefix("Pictures/")), name)
                                    if (f.delete()) {
                                        count++
                                        MediaScannerConnection.scanFile(this, arrayOf(f.absolutePath), null, null)
                                    }
                                }
                            } catch (_: Exception) {
                            }
                        }
                        runOnUiThread { result.success(count) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun cropToJpeg(path: String, target: Double): ByteArray {
        val exif = ExifInterface(path)
        val orientation = exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        val degrees = when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90
            ExifInterface.ORIENTATION_ROTATE_180 -> 180
            ExifInterface.ORIENTATION_ROTATE_270 -> 270
            else -> 0
        }

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        val rawW = bounds.outWidth
        val rawH = bounds.outHeight
        if (rawW <= 0 || rawH <= 0) throw IllegalStateException("Foto tidak dapat dibaca")

        val swap = degrees == 90 || degrees == 270
        val dw = if (swap) rawH else rawW
        val dh = if (swap) rawW else rawH

        var cw = dw
        var ch = dh
        val current = dw.toDouble() / dh.toDouble()
        if (target > 0 && abs(current - target) > 0.01) {
            if (current > target) {
                cw = (dh * target).roundToInt()
            } else {
                ch = (dw / target).roundToInt()
            }
        }
        cw = cw.coerceIn(1, dw)
        ch = ch.coerceIn(1, dh)
        val x0 = (dw - cw) / 2
        val y0 = (dh - ch) / 2
        val x1 = x0 + cw
        val y1 = y0 + ch

        // Ubah area potong (koordinat tampilan) ke koordinat mentah sebelum dirotasi.
        val rect = when (degrees) {
            90 -> Rect(y0, rawH - x1, y1, rawH - x0)
            180 -> Rect(rawW - x1, rawH - y1, rawW - x0, rawH - y0)
            270 -> Rect(rawW - y1, x0, rawW - y0, x1)
            else -> Rect(x0, y0, x1, y1)
        }

        val decoder = BitmapRegionDecoder.newInstance(path, false)
            ?: throw IllegalStateException("Decoder gagal dibuat")
        var bmp: Bitmap = try {
            decoder.decodeRegion(rect, BitmapFactory.Options())
                ?: throw IllegalStateException("Foto gagal didecode")
        } finally {
            decoder.recycle()
        }
        if (degrees != 0) {
            val m = Matrix()
            m.postRotate(degrees.toFloat())
            val rotated = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
            if (rotated !== bmp) bmp.recycle()
            bmp = rotated
        }
        val out = ByteArrayOutputStream(1 shl 20)
        bmp.compress(Bitmap.CompressFormat.JPEG, 95, out)
        bmp.recycle()
        return out.toByteArray()
    }

    private fun saveToGallery(bytes: ByteArray, name: String, relative: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                put(MediaStore.Images.Media.RELATIVE_PATH, relative)
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore insert gagal")
            try {
                contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                    ?: throw IllegalStateException("Output MediaStore tidak tersedia")
                val done = ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }
                contentResolver.update(uri, done, null, null)
            } catch (e: Exception) {
                contentResolver.delete(uri, null, null)
                throw e
            }
        } else {
            val pictures = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
            val folder = File(pictures, relative.removePrefix("Pictures/"))
            if (!folder.exists() && !folder.mkdirs()) throw IllegalStateException("Folder Galeri gagal dibuat")
            val file = File(folder, name)
            FileOutputStream(file).use { it.write(bytes) }
            MediaScannerConnection.scanFile(this, arrayOf(file.absolutePath), arrayOf("image/jpeg"), null)
        }
    }
}
