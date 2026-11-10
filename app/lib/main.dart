import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:vibration/vibration.dart';
import 'package:webview_flutter/webview_flutter.dart';

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

  Future<void> init() async {
    await MobileAds.instance.initialize();
    _loadInterstitial();
    _loadRewarded();
  }

  void _loadInterstitial() {
    InterstitialAd.load(
      adUnitId: _interstitialId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) => _interstitial = ad,
        onAdFailedToLoad: (_) {
          _interstitial = null;
          Future.delayed(const Duration(seconds: 30), _loadInterstitial);
        },
      ),
    );
  }

  void _loadRewarded() {
    RewardedAd.load(
      adUnitId: _rewardedId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) => _rewarded = ad,
        onAdFailedToLoad: (_) {
          _rewarded = null;
          Future.delayed(const Duration(seconds: 30), _loadRewarded);
        },
      ),
    );
  }

  /// Shows an interstitial if one is ready; [done] is always called exactly once.
  void showInterstitial(void Function() done) {
    final ad = _interstitial;
    if (ad == null) {
      _loadInterstitial();
      done();
      return;
    }
    _interstitial = null;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (a) {
        a.dispose();
        _loadInterstitial();
        done();
      },
      onAdFailedToShowFullScreenContent: (a, _) {
        a.dispose();
        _loadInterstitial();
        done();
      },
    );
    ad.show();
  }

  /// Shows a rewarded ad; [done] receives true only if the reward was earned.
  void showRewarded(void Function(bool earned) done) {
    final ad = _rewarded;
    if (ad == null) {
      _loadRewarded();
      done(false);
      return;
    }
    _rewarded = null;
    var earned = false;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (a) {
        a.dispose();
        _loadRewarded();
        done(earned);
      },
      onAdFailedToShowFullScreenContent: (a, _) {
        a.dispose();
        _loadRewarded();
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

  void _onMessage(JavaScriptMessage m) {
    try {
      final j = jsonDecode(m.message) as Map<String, dynamic>;
      switch (j['t']) {
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
              WebViewWidget(controller: _web),
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
