package io.github.joemj.audiojoe

import android.content.Intent
import android.os.StatFs
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // App update (github build): hands a downloaded APK to the package installer, which asks
        // the user. The file lies in the app's cache; the FileProvider is declared in the github
        // flavor's manifest only.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.github.joemj.audiojoe/install").setMethodCallHandler { call, result ->
            if (call.method != "apk") return@setMethodCallHandler result.notImplemented()
            try {
                val file = File(call.arguments as String)
                val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
                val intent = Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, "application/vnd.android.package-archive")
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                startActivity(intent)
                result.success(null)
            } catch (e: Exception) {
                result.error("install", e.message, null)
            }
        }
        // "text": hands the error log to the system's share sheet (Settings → Maintenance → Error log).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.github.joemj.audiojoe/share").setMethodCallHandler { call, result ->
            if (call.method != "text") return@setMethodCallHandler result.notImplemented()
            try {
                val send = Intent(Intent.ACTION_SEND).setType("text/plain")
                    .putExtra(Intent.EXTRA_SUBJECT, "audiojoe error log")
                    .putExtra(Intent.EXTRA_TEXT, call.arguments as String)
                startActivity(Intent.createChooser(send, null))
                result.success(null)
            } catch (e: Exception) {
                result.error("share", e.message, null)
            }
        }
        // "free" with a path: free bytes on its volume (the app's own storage, no permission).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.github.joemj.audiojoe/storage").setMethodCallHandler { call, result ->
            if (call.method != "free") return@setMethodCallHandler result.notImplemented()
            try {
                result.success(StatFs(call.arguments as String).availableBytes)
            } catch (e: Exception) {
                result.error("statfs", e.message, null)
            }
        }
    }
}
