#!/usr/bin/env python3
"""Creates a fresh Flutter project (build_app/), copies the game + Dart code into it and patches
Android/iOS settings (AdMob app id, permissions, min SDK, app name). Run from the repo root."""
import json, pathlib, re, shutil, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
cfg = json.loads((root / 'app/assets/app_config.json').read_text())
org, name = cfg['applicationId'].rsplit('.', 1)
noads = '--noads' in sys.argv
crash = '--crashlog' in sys.argv
b = root / ('build_app_noads' if noads else ('build_app_crash' if crash else 'build_app'))
shutil.rmtree(b, ignore_errors=True)
subprocess.check_call(['flutter', 'create', '--platforms=android,ios', '--org', org,
                       '--project-name', name, b.name], cwd=root)
shutil.rmtree(b / 'test', ignore_errors=True)
shutil.rmtree(b / 'lib')
shutil.copytree(root / ('app/lib_noads' if noads else 'app/lib'), b / 'lib')
shutil.copytree(root / 'app/assets', b / 'assets')
shutil.copy(root / ('app/pubspec_noads.yaml' if noads else 'app/pubspec.yaml'), b / 'pubspec.yaml')

test = cfg.get('useTestAds', True)
and_id = 'ca-app-pub-3940256099942544~3347511713' if test else cfg['android']['appId']
ios_id = 'ca-app-pub-3940256099942544~1458002511' if test else cfg['ios']['appId']

# ---- Android manifest
mf = b / 'android/app/src/main/AndroidManifest.xml'
t = mf.read_text()
t = re.sub(r'android:label="[^"]*"', 'android:label="%s"' % cfg['appName'], t, count=1)
perms = '<uses-permission android:name="android.permission.INTERNET"/>\n    '
perms += '<uses-permission android:name="android.permission.VIBRATE"/>\n    '
if not noads:
    perms += '<uses-permission android:name="com.google.android.gms.permission.AD_ID"/>\n    '
t = t.replace('<application', perms + '<application', 1)
meta = ('<meta-data android:name="com.google.android.gms.ads.APPLICATION_ID" '
        'android:value="%s"/>' % and_id)
if not noads:
    t = re.sub(r'(<application[^>]*>)', lambda m: m.group(1) + '\n        ' + meta, t, count=1)
assert noads or 'APPLICATION_ID' in t, 'AdMob meta-data was not inserted'
if crash:
    # Diagnostic: show the uncaught native exception as a Toast so a launch crash can be read off the screen.
    src = None
    for ext in ('kt', 'java'):
        src = next((b / 'android/app/src/main').rglob('MainActivity.' + ext), None) or src
    pkg = re.search(r'package\s+([\w.]+)', src.read_text()).group(1)
    (src.parent / 'CrashApp.kt').write_text('''package %s

import android.app.Application
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.widget.Toast

class CrashApp : Application() {
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        val old = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { th, e ->
            try {
                val sb = StringBuilder(e.toString())
                var c = e.cause
                while (c != null) { sb.append("\\nCAUSE: ").append(c.toString()); c = c.cause }
                e.stackTrace.take(6).forEach { sb.append("\\n  ").append(it.toString()) }
                val msg = sb.toString()
                Thread {
                    Looper.prepare()
                    repeat(3) { Toast.makeText(base, msg, Toast.LENGTH_LONG).show() }
                    Handler(Looper.myLooper()!!).postDelayed({ Looper.myLooper()!!.quit() }, 9000)
                    Looper.loop()
                }.start()
                Thread.sleep(9000)
            } catch (x: Throwable) {}
            old?.uncaughtException(th, e)
        }
    }
}
''' % pkg)
    t = t.replace('android:name="${applicationName}"', 'android:name=".CrashApp"', 1)
    assert 'CrashApp' in t, 'manifest not patched'
mf.write_text(t)

# ---- Android min SDK (ads + webview need >= 23/24)
patched = False
for f in ('android/app/build.gradle.kts', 'android/app/build.gradle'):
    p = b / f
    if not p.exists():
        continue
    s = p.read_text()
    kts = f.endswith('kts')
    s2 = re.sub(r'minSdk(Version)?\s*=?\s*flutter\.minSdkVersion',
                'minSdk = 24' if kts else 'minSdkVersion 24', s)
    if s2 != s:
        patched = True
    # Lint crashes inside a dependency on CI; it is not needed to produce the APK.
    if 'checkReleaseBuilds' not in s2:
        s2 = re.sub(r'(^\s*android\s*\{)', r'\1\n    lint {\n        checkReleaseBuilds = false\n        abortOnError = false\n    }', s2, count=1, flags=re.M)
        assert 'checkReleaseBuilds' in s2, 'lint patch failed'
    # Release shrinking (R8) strips Room's generated classes used by WorkManager (ads SDK) -> crash at launch.
    if 'isMinifyEnabled' not in s2 and 'minifyEnabled' not in s2:
        rel = ('isMinifyEnabled = false\n            isShrinkResources = false' if kts
               else 'minifyEnabled false\n            shrinkResources false')
        s3 = re.sub(r'(\brelease\s*\{)', lambda m: m.group(1) + '\n            ' + rel, s2, count=1)
        assert s3 != s2, 'could not disable minify in release buildType'
        s2 = s3
    if s2 != s:
        p.write_text(s2)
if not patched:
    print('WARNING: could not patch minSdk; check android/app/build.gradle(.kts)', file=sys.stderr)

gp = b / 'android/gradle.properties'
if gp.exists():
    gp.write_text(gp.read_text().rstrip('\n') + '\nandroid.enableR8.fullMode=false\n')

# ---- Launch window background (avoid white flash before Flutter draws)
for d in ('drawable', 'drawable-v21'):
    lb = b / 'android/app/src/main/res' / d / 'launch_background.xml'
    if lb.parent.exists():
        lb.write_text('<?xml version="1.0" encoding="utf-8"?>\n<layer-list xmlns:android="http://schemas.android.com/apk/res/android">\n'
                      '    <item><shape android:shape="rectangle"><solid android:color="#1E120A"/></shape></item>\n</layer-list>\n')

# ---- iOS Info.plist
pl = b / 'ios/Runner/Info.plist'
s = pl.read_text()
s = re.sub(r'(<key>CFBundleDisplayName</key>\s*<string>)[^<]*', lambda m: m.group(1) + cfg['appName'], s)
add = '\t<key>GADApplicationIdentifier</key>\n\t<string>%s</string>\n' % ios_id
head, tail = s.rsplit('</dict>', 1)
pl.write_text(head + ('' if noads else add) + '</dict>' + tail)
print('Prepared', b)
