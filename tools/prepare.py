#!/usr/bin/env python3
"""Creates a fresh Flutter project (build_app/), copies the game + Dart code into it and patches
Android/iOS settings (AdMob app id, permissions, min SDK, app name). Run from the repo root."""
import json, pathlib, re, shutil, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
cfg = json.loads((root / 'app/assets/app_config.json').read_text())
org, name = cfg['applicationId'].rsplit('.', 1)
b = root / 'build_app'
shutil.rmtree(b, ignore_errors=True)
subprocess.check_call(['flutter', 'create', '--platforms=android,ios', '--org', org,
                       '--project-name', name, 'build_app'], cwd=root)
shutil.rmtree(b / 'test', ignore_errors=True)
shutil.rmtree(b / 'lib')
shutil.copytree(root / 'app/lib', b / 'lib')
shutil.copytree(root / 'app/assets', b / 'assets')
shutil.copy(root / 'app/pubspec.yaml', b / 'pubspec.yaml')

test = cfg.get('useTestAds', True)
and_id = 'ca-app-pub-3940256099942544~3347511713' if test else cfg['android']['appId']
ios_id = 'ca-app-pub-3940256099942544~1458002511' if test else cfg['ios']['appId']

# ---- Android manifest
mf = b / 'android/app/src/main/AndroidManifest.xml'
t = mf.read_text()
t = re.sub(r'android:label="[^"]*"', 'android:label="%s"' % cfg['appName'], t, count=1)
perms = ('<uses-permission android:name="android.permission.INTERNET"/>\n'
         '    <uses-permission android:name="com.google.android.gms.permission.AD_ID"/>\n    ')
t = t.replace('<application', perms + '<application', 1)
meta = ('<meta-data android:name="com.google.android.gms.ads.APPLICATION_ID" '
        'android:value="%s"/>' % and_id)
t = re.sub(r'(<application[^>]*>)', lambda m: m.group(1) + '\n        ' + meta, t, count=1)
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
        p.write_text(s2)
        patched = True
if not patched:
    print('WARNING: could not patch minSdk; check android/app/build.gradle(.kts)', file=sys.stderr)

# ---- iOS Info.plist
pl = b / 'ios/Runner/Info.plist'
s = pl.read_text()
s = re.sub(r'(<key>CFBundleDisplayName</key>\s*<string>)[^<]*', lambda m: m.group(1) + cfg['appName'], s)
add = '\t<key>GADApplicationIdentifier</key>\n\t<string>%s</string>\n' % ios_id
head, tail = s.rsplit('</dict>', 1)
pl.write_text(head + add + '</dict>' + tail)
print('Prepared', b)
