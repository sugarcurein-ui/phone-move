"""Patch the generated Android project: manifest (permissions, cleartext http,
Telugu app name, Share-menu entry) and MainActivity (receives shared files)."""
import pathlib, re, glob

p = pathlib.Path('android/app/src/main/AndroidManifest.xml')
s = p.read_text(encoding='utf-8')

perms = '''    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>
    <uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE"/>
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"/>
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29"/>
    <uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
'''

if 'MANAGE_EXTERNAL_STORAGE' not in s:
    s = s.replace('<application', perms + '    <application', 1)

s = re.sub(r'android:label="[^"]*"', 'android:label="ఫోన్ మూవ్"', s, count=1)

if 'usesCleartextTraffic' not in s:
    s = s.replace('<application',
                  '<application android:usesCleartextTraffic="true" android:requestLegacyExternalStorage="true"', 1)

share_filters = '''            <intent-filter>
                <action android:name="android.intent.action.SEND"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <data android:mimeType="*/*"/>
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.SEND_MULTIPLE"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <data android:mimeType="*/*"/>
            </intent-filter>
'''
if 'android.intent.action.SEND"' not in s:
    s = s.replace('</activity>', share_filters + '        </activity>', 1)

p.write_text(s, encoding='utf-8')
print(s)
assert 'MANAGE_EXTERNAL_STORAGE' in s and 'usesCleartextTraffic' in s
assert 'android.intent.action.SEND_MULTIPLE' in s

# ---- MainActivity: receive files shared from other apps
files = glob.glob('android/app/src/main/**/MainActivity.*', recursive=True)
assert files, 'MainActivity not found'
ma = pathlib.Path(files[0])
old = ma.read_text(encoding='utf-8')
m = re.search(r'^package\s+([\w.]+)', old, re.M)
pkg = m.group(1) if m else 'com.swamy.phonemove'

kotlin = '''package PKG

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pending: Intent? = null
    private var ready = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pending = intent
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "phonemove/share")
        ch.setMethodCallHandler { call, result ->
            if (call.method == "getShared") {
                ready = true
                val first = pending
                pending = null
                resolve(first) { list -> result.success(list) }
            } else {
                result.notImplemented()
            }
        }
        channel = ch
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (!ready) {
            pending = intent
            return
        }
        resolve(intent) { list ->
            if (list.isNotEmpty()) channel?.invokeMethod("shared", list)
        }
    }

    @Suppress("DEPRECATION")
    private fun collectUris(it: Intent): List<Uri> {
        val uris = ArrayList<Uri>()
        if (it.action == Intent.ACTION_SEND) {
            val u: Uri? = if (Build.VERSION.SDK_INT >= 33)
                it.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else it.getParcelableExtra(Intent.EXTRA_STREAM)
            if (u != null) uris.add(u)
        } else {
            val l: ArrayList<Uri>? = if (Build.VERSION.SDK_INT >= 33)
                it.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else it.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
            if (l != null) uris.addAll(l)
        }
        if (uris.isEmpty()) {
            val cd = it.clipData
            if (cd != null) {
                for (i in 0 until cd.itemCount) {
                    val u = cd.getItemAt(i).uri
                    if (u != null) uris.add(u)
                }
            }
        }
        return uris
    }

    private fun resolve(it: Intent?, cb: (List<String>) -> Unit) {
        if (it == null ||
            (it.action != Intent.ACTION_SEND && it.action != Intent.ACTION_SEND_MULTIPLE)
        ) {
            cb(emptyList())
            return
        }
        val uris = collectUris(it)
        val main = Handler(Looper.getMainLooper())
        Thread {
            val out = ArrayList<String>()
            try {
                cleanOld()
                val dir = File(cacheDir, "share/" + System.currentTimeMillis())
                for (u in uris) {
                    try {
                        val p = toPath(u, dir)
                        if (p != null && !out.contains(p)) out.add(p)
                    } catch (e: Exception) {
                    }
                }
            } catch (e: Exception) {
            }
            main.post { cb(out) }
        }.start()
    }

    /** remove copies made for earlier shares (older than a day) */
    private fun cleanOld() {
        val root = File(cacheDir, "share")
        val limit = System.currentTimeMillis() - 24L * 3600 * 1000
        root.listFiles()?.forEach { d ->
            if (d.lastModified() < limit) d.deleteRecursively()
        }
    }

    private fun toPath(u: Uri, dir: File): String? {
        if (u.scheme == "file") {
            val f = File(u.path ?: return null)
            return if (f.isFile && f.canRead()) f.absolutePath else null
        }
        // real path when the phone lets us read it (no copy, so big videos are quick)
        try {
            contentResolver.query(u, arrayOf("_data"), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val path = c.getString(0)
                    if (path != null) {
                        val f = File(path)
                        if (f.isFile && f.canRead()) return f.absolutePath
                    }
                }
            }
        } catch (e: Exception) {
        }
        // otherwise copy into app cache
        var name = "file"
        try {
            contentResolver.query(u, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val n = c.getString(0)
                    if (n != null && n.isNotEmpty()) name = n
                }
            }
        } catch (e: Exception) {
        }
        name = name.replace('/', '_')
        dir.mkdirs()
        var target = File(dir, name)
        var k = 2
        while (target.exists()) {
            val dot = name.lastIndexOf('.')
            target = if (dot > 0) File(dir, name.substring(0, dot) + " (" + k + ")" + name.substring(dot))
            else File(dir, name + " (" + k + ")")
            k++
        }
        contentResolver.openInputStream(u)?.use { input ->
            FileOutputStream(target).use { output ->
                val buf = ByteArray(1024 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n <= 0) break
                    output.write(buf, 0, n)
                }
            }
        } ?: return null
        return target.absolutePath
    }
}
'''.replace('PKG', pkg)
ma.write_text(kotlin, encoding='utf-8')
print('MainActivity patched:', ma, pkg)
