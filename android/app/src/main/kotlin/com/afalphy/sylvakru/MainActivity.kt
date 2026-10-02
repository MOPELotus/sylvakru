// Copyright 2026 MOPELotus. Linsen additions, Apache-2.0.
package com.mopelotus.linsen

import android.app.Activity
import android.content.Intent
import android.net.Uri
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : AudioServiceActivity() {
    private var saveResult: MethodChannel.Result? = null
    private val saveRequest = 17042

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.mopelotus.linsen/export")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickSave" -> {
                        if (saveResult != null) {
                            result.error("busy", "已有保存窗口，请先完成或取消", null)
                        } else {
                            saveResult = result
                            try {
                                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = call.argument<String>("mimeType") ?: "application/octet-stream"
                                    putExtra(Intent.EXTRA_TITLE, call.argument<String>("fileName") ?: "song.audio")
                                }
                                startActivityForResult(intent, saveRequest)
                            } catch (error: Exception) {
                                saveResult = null
                                result.error("picker_error", "无法打开保存窗口", error.javaClass.simpleName)
                            }
                        }
                    }
                    "copyToUri" -> {
                        try {
                            val source = File(call.argument<String>("sourcePath") ?: "").canonicalFile
                            val roots = listOf(filesDir.canonicalPath, cacheDir.canonicalPath)
                            require(source.isFile && roots.any { source.path.startsWith(it + File.separator) })
                            val uri = Uri.parse(call.argument<String>("uri") ?: "")
                            require(uri.scheme == "content")
                            Thread {
                                try {
                                    source.inputStream().use { input ->
                                        val output = contentResolver.openOutputStream(uri, "wt")
                                            ?: throw java.io.IOException("No output stream")
                                        output.use { input.copyTo(it, 64 * 1024) }
                                    }
                                    runOnUiThread { result.success(true) }
                                } catch (error: Exception) {
                                    // Remove our incomplete document when the provider permits it.
                                    try { contentResolver.delete(uri, null, null) } catch (_: Exception) {}
                                    runOnUiThread { result.error("save_error", "保存失败，请重试", error.javaClass.simpleName) }
                                }
                            }.start()
                        } catch (error: Exception) {
                            result.error("invalid_export", "无效导出文件", error.javaClass.simpleName)
                        }
                    }
                    "discardUri" -> {
                        try {
                            val uri = Uri.parse(call.argument<String>("uri") ?: "")
                            require(uri.scheme == "content")
                            contentResolver.delete(uri, null, null)
                            result.success(null)
                        } catch (_: Exception) { result.success(null) }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == saveRequest) {
            val pending = saveResult
            saveResult = null
            pending?.success(if (resultCode == Activity.RESULT_OK) data?.data?.toString() else null)
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        saveResult?.success(null)
        saveResult = null
        super.onDestroy()
    }
}
