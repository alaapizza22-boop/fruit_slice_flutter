import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Google's public sample ad units. Used whenever "useTestAds" is true in assets/app_config.json.
const _testInterstitial = {
  'android': 'ca-app-pub-3940256099942544/1033173712',
  'ios': 'ca-app-pub-3940256099942544/4411468910',
};
const _testRewarded = {
  'android': 'ca-app-pub-3940256099942544/5224354917',
  'ios': 'ca-app-pub-3940256099942544/1712485313',
};

final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (d) => lastError.value = d.exceptionAsString();
    try {
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      final cfg = jsonDecode(await rootBundle.loadString('assets/app_config.json'))
          as Map<String, dynamic>;
      runApp(App(cfg: cfg));
    } catch (e, s) {
      runApp(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SafeArea(top: false, bottom: false, 
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText('Startup error:\n$e\n\n$s'),
            ),
          ),
        ),
      ));
    }
  }, (e, s) => lastError.value = '$e');
}

class App extends StatelessWidget {
  const App({super.key, required this.cfg});
  final Map<String, dynamic> cfg;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: cfg['appName'] as String? ?? 'Fruit Slice',
        theme: ThemeData.dark(),
        home: GamePage(cfg: cfg),
      );
}

/// Diagnostic build: no ads at all. Every ad request is answered immediately.
class AdsManager {
  AdsManager(Map<String, dynamic> cfg);
  Future<void> init() async {}
  void showInterstitial(void Function() done) => done();
  void showRewarded(void Function(bool earned) done) => done(true);
}

class GamePage extends StatefulWidget {
  const GamePage({super.key, required this.cfg});
  final Map<String, dynamic> cfg;

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> with WidgetsBindingObserver {
  late final WebViewController _web;
  late final AdsManager _ads;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future<void>.delayed(const Duration(seconds: 12), () => _ready.value = true);
    _ads = AdsManager(widget.cfg);
    _ads.init().catchError((Object e) {
      lastError.value = 'Ads init: $e';
    });
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF1E120A))
      ..setNavigationDelegate(NavigationDelegate(
        onWebResourceError: (e) => lastError.value = 'WebView: ${e.description}',
      ))
      ..addJavaScriptChannel('AppChannel', onMessageReceived: _onMessage)
      ..loadFlutterAsset('assets/game/index.html');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _web.runJavaScript('window.__pause&&window.__pause()');
    }
  }

  final ValueNotifier<bool> _ready = ValueNotifier<bool>(false);

  void _onMessage(JavaScriptMessage m) {
    try {
      final j = jsonDecode(m.message) as Map<String, dynamic>;
      switch (j['t']) {
        case 'ready':
          _ready.value = true;
          break;
        case 'vib':
          final n = (j['n'] as num?)?.toInt() ?? 15;
          final ms = n <= 12 ? 15 : (n <= 24 ? 28 : 60);
          Vibration.hasVibrator().then((has) {
            if (has == true) {
              Vibration.vibrate(duration: ms, amplitude: 160);
            } else {
              n <= 12 ? HapticFeedback.lightImpact() : HapticFeedback.mediumImpact();
            }
          });
          break;
        case 'ad':
          final kind = j['kind'] as String;
          if (kind == 'rewarded') {
            _ads.showRewarded((ok) => _adDone(kind, ok));
          } else {
            _ads.showInterstitial(() => _adDone(kind, true));
          }
          break;
      }
    } catch (_) {}
  }

  void _adDone(String kind, bool ok) =>
      _web.runJavaScript("window.__adDone&&window.__adDone('$kind',$ok)");

  Future<void> _onBack() async {
    final r = await _web
        .runJavaScriptReturningResult('window.__back?window.__back():"exit"');
    if (r.toString().replaceAll('"', '') == 'exit') {
      SystemNavigator.pop();
    }
  }

  Widget _webWidget() {
    final params = PlatformWebViewWidgetCreationParams(
        controller: _web.platform, layoutDirection: TextDirection.ltr);
    if (Platform.isAndroid) {
      return WebViewWidget.fromPlatformCreationParams(
        params: AndroidWebViewWidgetCreationParams
            .fromPlatformWebViewWidgetCreationParams(params,
                displayWithHybridComposition: true),
      );
    }
    return WebViewWidget(controller: _web);
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _onBack();
        },
        child: Scaffold(
          backgroundColor: const Color(0xFF1E120A),
          body: SafeArea(top: false, bottom: false, 
            child: Stack(children: [
              _webWidget(),
              ValueListenableBuilder<bool>(
                valueListenable: _ready,
                builder: (_, ready, __) => IgnorePointer(
                  ignoring: ready,
                  child: AnimatedOpacity(
                    opacity: ready ? 0 : 1,
                    duration: const Duration(milliseconds: 350),
                    child: Container(
                      color: const Color(0xFF1E120A),
                      alignment: Alignment.center,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Image.asset('assets/icon.png', width: 120, height: 120),
                        const SizedBox(height: 24),
                        const SizedBox(
                            width: 26,
                            height: 26,
                            child: CircularProgressIndicator(
                                strokeWidth: 3, color: Color(0xFFFFC23C))),
                      ]),
                    ),
                  ),
                ),
              ),
              ValueListenableBuilder<String?>(
                valueListenable: lastError,
                builder: (_, err, __) => err == null
                    ? const SizedBox.shrink()
                    : Align(
                        alignment: Alignment.topCenter,
                        child: GestureDetector(
                          onTap: () => lastError.value = null,
                          child: Container(
                            width: double.infinity,
                            color: const Color(0xDD7A1010),
                            padding: const EdgeInsets.all(8),
                            child: Text('Error (tap to hide): $err',
                                style: const TextStyle(fontSize: 11)),
                          ),
                        ),
                      ),
              ),
            ]),
          ),
        ),
      );
}
