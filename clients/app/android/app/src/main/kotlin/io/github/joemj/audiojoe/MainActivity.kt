package io.github.joemj.audiojoe

import android.content.Intent
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
    }
}
