# Fruit Slice – Flutter wrapper (WebView + AdMob)

The game itself is `app/assets/game/index.html` (one self-contained HTML file). Flutter loads it in a WebView and adds:
- **Interstitial ad** before every 3rd round.
- **Rewarded ad** on the game-over screen ("Continue – watch a short ad", once per round).
- Haptics, Android back button, auto-pause when the app goes to the background.

GitHub Actions generates the Android/iOS folders, patches them and builds, so you don't need Flutter installed.

## الخطوات بالعربي
1. ارفع كل محتويات هذا المجلد (فك الضغط الأول) على مستودع GitHub فاضي، في الفرع `main`. تأكد إن مجلد `.github` اترفع (هو مخفي).
2. افتح تبويب **Actions** ← **Build app**. هيشتغل تلقائي عند الرفع. أو اضغط **Run workflow**.
3. بعد ما ينجح (حوالي 5–10 دقايق) افتح الـ run ونزّل **android-apk** من Artifacts. فك ضغطه وثبّته على موبايلك للتجربة.
4. لو فشل: افتح الخطوة الحمرا وابعتلي نص الخطأ.

## Before you publish (important)
1. **Package name** – edit `applicationId` in `app/assets/app_config.json` (e.g. `com.yourname.fruitslice`). It cannot change after you publish.
2. **AdMob** – the project ships with Google's *test* ads (`"useTestAds": true`). When your AdMob app + ad units exist, fill the `appId`, `interstitial`, `rewarded` values for android/ios in the same file and set `"useTestAds": false`. Never tap your own live ads.
3. **Play Store signing** – the AAB produced now is debug-signed; Google Play needs your upload key. Ask me to add the signing step when you have a keystore.
4. **Fruit photos** – replace the images with ones you are licensed to use commercially. The game file embeds them as base64 (`const PHOTO=...`).
5. **Privacy policy** – `PRIVACY_POLICY.md` is a template; host it on a web page and paste the URL into the store listing. Ads require it.
6. **iOS** – run the workflow manually and tick *Also build iOS*. That produces an unsigned app only; publishing needs an Apple Developer account (99 USD/year) and signing certificates.
7. For EU users add Google's consent message (UMP) before shipping there.

## Updating the game
Replace `app/assets/game/index.html` with a new version and push. Nothing else changes.

## Layout
```
app/lib/main.dart            Flutter app: WebView, ads, haptics, back button
app/assets/game/index.html   the game
app/assets/app_config.json   app name, package id, AdMob ids
app/assets/icon.png          1024px launcher icon
tools/prepare.py             creates the Flutter project and patches Android/iOS settings
.github/workflows/build.yml  the build
```
Not tested on a real device or build server yet – the first Actions run may need a small fix; send me the log.
