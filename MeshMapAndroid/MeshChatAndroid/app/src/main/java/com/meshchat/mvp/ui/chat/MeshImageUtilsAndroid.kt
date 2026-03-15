package com.meshchat.mvp.ui.chat

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream

object MeshImageUtilsAndroid {
    private const val MAX_DIMENSION = 320
    private const val MAX_JPEG_BYTES = 12 * 1024

    fun compressForMesh(context: Context, rawBytes: ByteArray): ByteArray? {
        val original = BitmapFactory.decodeByteArray(rawBytes, 0, rawBytes.size) ?: return null
        val w = original.width
        val h = original.height
        val maxSide = maxOf(w, h)
        val scaled = if (maxSide > MAX_DIMENSION) {
            val scale = MAX_DIMENSION.toFloat() / maxSide
            Bitmap.createScaledBitmap(original, (w * scale).toInt(), (h * scale).toInt(), true)
        } else original

        var quality = 72
        var out = compress(scaled, quality)
        while (out.size > MAX_JPEG_BYTES && quality > 28) {
            quality -= 8
            out = compress(scaled, quality)
        }
        return if (out.size <= MAX_JPEG_BYTES) out else null
    }

    fun prepareThumbnailData(rawBytes: ByteArray): ByteArray? {
        val original = BitmapFactory.decodeByteArray(rawBytes, 0, rawBytes.size) ?: return null
        val maxDim = 200
        val w = original.width
        val h = original.height
        val maxSide = maxOf(w, h)
        val scaled = if (maxSide > maxDim) {
            val scale = maxDim.toFloat() / maxSide
            Bitmap.createScaledBitmap(original, (w * scale).toInt(), (h * scale).toInt(), true)
        } else original
        return compress(scaled, 35)
    }

    private fun compress(bmp: Bitmap, quality: Int): ByteArray {
        val bos = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, quality, bos)
        return bos.toByteArray()
    }
}
