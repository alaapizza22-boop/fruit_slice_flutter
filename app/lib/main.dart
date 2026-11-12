import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
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

/// Loads, shows and re-loads interstitial and rewarded ads.
class AdsManager {
  AdsManager(this.cfg);
  final Map<String, dynamic> cfg;
  InterstitialAd? _interstitial;
  RewardedAd? _rewarded;

  String get _os => Platform.isIOS ? 'ios' : 'android';
  bool get _test => cfg['useTestAds'] == true;
  Map<String, dynamic> get _ids => cfg[_os] as Map<String, dynamic>;
  String get _interstitialId =>
      _test ? _testInterstitial[_os]! : _ids['interstitial'] as String;
  String get _rewardedId =>
      _test ? _testRewarded[_os]! : _ids['rewarded'] as String;

  void Function(bool ready)? onRewardedState;
  bool _loadingI = false, _loadingR = false, _started = false;
  bool _playing = false;
  set playing(bool v) {
    _playing = v;
    if (!v) ensureLoaded();
  }

  int _failI = 0, _failR = 0;

  Duration _backoff(int fails) =>
      Duration(seconds: [15, 30, 60, 120][fails.clamp(0, 3)]);

  Future<void> init() async {
    await MobileAds.instance.initialize();
    _started = true;
    _loadInterstitial();
    _loadRewarded();
  }

  /// Called when the app comes back to the foreground (e.g. internet returned).
  void ensureLoaded() {
    if (!_started) return;
    if (_interstitial == null) _loadInterstitial();
    if (_rewarded == null) _loadRewarded();
    onRewardedState?.call(_rewarded != null);
  }

  void _loadInterstitial() {
    if (_playing || _loadingI || _interstitial != null) return;
    _loadingI = true;
    InterstitialAd.load(
      adUnitId: _interstitialId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _loadingI = false;
          _failI = 0;
          _interstitial?.dispose();
          _interstitial = ad;
        },
        onAdFailedToLoad: (_) {
          _loadingI = false;
          _interstitial = null;
          final d = _backoff(_failI++);
          Future.delayed(d, _loadInterstitial);
        },
      ),
    );
  }

  void _loadRewarded() {
    if (_playing || _loadingR || _rewarded != null) return;
    _loadingR = true;
    RewardedAd.load(
      adUnitId: _rewardedId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          _loadingR = false;
          _failR = 0;
          _rewarded?.dispose();
          _rewarded = ad;
          onRewardedState?.call(true);
        },
        onAdFailedToLoad: (_) {
          _loadingR = false;
          _rewarded = null;
          onRewardedState?.call(false);
          final d = _backoff(_failR++);
          Future.delayed(d, _loadRewarded);
        },
      ),
    );
  }

  /// Shows an interstitial if one is ready; [done] is always called exactly once.
  void showInterstitial(void Function() done) {
    final ad = _interstitial;
    if (ad == null) {
      Future<void>.delayed(const Duration(seconds: 3), _loadInterstitial);
      done();
      return;
    }
    _interstitial = null;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (a) {
        a.dispose();
        Future<void>.delayed(const Duration(seconds: 3), _loadInterstitial);
        done();
      },
      onAdFailedToShowFullScreenContent: (a, _) {
        a.dispose();
        Future<void>.delayed(const Duration(seconds: 3), _loadInterstitial);
        done();
      },
    );
    ad.show();
  }

  /// Shows a rewarded ad; [done] receives true only if the reward was earned.
  void showRewarded(void Function(bool earned) done) {
    final ad = _rewarded;
    if (ad == null) {
      Future<void>.delayed(const Duration(seconds: 3), _loadRewarded);
      done(false);
      return;
    }
    _rewarded = null;
    onRewardedState?.call(false);
    var earned = false;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (a) {
        a.dispose();
        Future<void>.delayed(const Duration(seconds: 3), _loadRewarded);
        done(earned);
      },
      onAdFailedToShowFullScreenContent: (a, _) {
        a.dispose();
        Future<void>.delayed(const Duration(seconds: 3), _loadRewarded);
        done(false);
      },
    );
    ad.show(onUserEarnedReward: (_, __) => earned = true);
  }
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
    _ads.onRewardedState = (r) {
      _web.runJavaScript('window.__adState&&window.__adState(${r ? "true" : "false"})');
    };
    Future<void>.delayed(const Duration(seconds: 4)).then((_) => _ads.init()).catchError((Object e) {
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
    } else {
      _ads.ensureLoaded();
    }
  }

  final ValueNotifier<bool> _ready = ValueNotifier<bool>(false);

  void _onMessage(JavaScriptMessage m) {
    try {
      final j = jsonDecode(m.message) as Map<String, dynamic>;
      switch (j['t']) {
        case 'play':
          _ads.playing = j['on'] == true;
          break;
        case 'ready':
          _ready.value = true;
          _ads.ensureLoaded();
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
                    child: const SplashView(),
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

class _HalfClipper extends CustomClipper<Path> {
  const _HalfClipper(this.first);
  final bool first;
  @override
  Path getClip(Size s) {
    final p = Path();
    if (first) {
      p..moveTo(0, 0)..lineTo(s.width, 0)..lineTo(0, s.height);
    } else {
      p..moveTo(s.width, 0)..lineTo(s.width, s.height)..lineTo(0, s.height);
    }
    return p..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> old) => false;
}

/// Same picture as the in-game splash, drawn natively so it shows the moment the app opens.
class SplashView extends StatelessWidget {
  const SplashView({super.key});

  Widget _half(bool first) => Transform.translate(
        offset: first ? const Offset(-5, -5) : const Offset(5, 5),
        child: Transform.rotate(
          angle: first ? -0.052 : 0.052,
          child: ClipPath(
            clipper: _HalfClipper(first),
            child: Image.asset('assets/apple.png', width: 112, height: 112, fit: BoxFit.contain),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final barW = (MediaQuery.of(context).size.width * 0.6).clamp(0.0, 220.0).toDouble();
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.2),
          radius: 1.0,
          colors: [Color(0xFF5A3A20), Color(0xFF2A1709), Color(0xFF150B05)],
          stops: [0.0, 0.62, 1.0],
        ),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 112, height: 112, child: Stack(children: [_half(true), _half(false)])),
          const SizedBox(height: 12),
          Image.asset('assets/brand_fruit.png', width: 104),
          const SizedBox(height: 4),
          Image.asset('assets/brand_slice.png', width: 178),
          const SizedBox(height: 30),
          Container(
            width: barW,
            height: 8,
            decoration: BoxDecoration(
              color: const Color(0x24FBEFD8),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.centerLeft,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 0.3),
              duration: const Duration(milliseconds: 1800),
              curve: Curves.easeOut,
              builder: (_, v, __) => Container(
                width: barW * v,
                height: 8,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [Color(0xFFFFD66B), Color(0xFFEE8A1A)]),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text('SHARPENING THE BLADES…',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2.4,
                  color: Color(0xFFD9C3A3),
                  decoration: TextDecoration.none)),
        ],
      ),
    );
  }
}
