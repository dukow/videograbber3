import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const VideoGrabberApp());

// ---------------------------------------------------------------------------
// Platform bridge
// ---------------------------------------------------------------------------

class Downloader {
  static const channel = MethodChannel('video_grabber/downloader');
  static const progressChannel = EventChannel('video_grabber/progress');

  static Future<String?> getSharedUrl() async =>
      await channel.invokeMethod<String>('getSharedUrl');

  static Future<Map?> getInfo(String url, {String? referer}) async =>
      await channel.invokeMethod<Map>(
          'getInfo', {'url': url, 'referer': referer});

  static Future<String?> download({
    required String id,
    required String url,
    required String quality,
    String? referer,
    String? title,
  }) async =>
      await channel.invokeMethod<String>('download', {
        'id': id,
        'url': url,
        'quality': quality,
        'referer': referer,
        'title': title,
      });

  static Future<void> cancel(String id) async =>
      await channel.invokeMethod('cancel', {'id': id});

  static Future<List?> getJobs() async =>
      await channel.invokeMethod<List>('getJobs');

  static Future<bool> requestBatteryExemption() async =>
      (await channel.invokeMethod<bool>('requestBatteryExemption')) ?? false;

  static Future<bool> updateEngine() async =>
      (await channel.invokeMethod<bool>('updateEngine')) ?? false;
}

// ---------------------------------------------------------------------------
// Download job model + in-memory store
// ---------------------------------------------------------------------------

class DownloadJob {
  final String id;
  String url;
  String title;
  String quality;
  String status; // queued | downloading | done | failed | cancelled
  double progress; // 0..100
  int eta; // seconds
  String error;
  String path;
  String? referer;

  DownloadJob({
    required this.id,
    required this.url,
    required this.title,
    required this.quality,
    this.status = 'queued',
    this.progress = 0,
    this.eta = 0,
    this.error = '',
    this.path = '',
    this.referer,
  });

  void applyUpdate(Map u) {
    status = (u['status'] ?? status).toString();
    if (u['progress'] != null) {
      progress = (u['progress'] as num).toDouble().clamp(0, 100);
    }
    if (u['eta'] != null) eta = (u['eta'] as num).toInt();
    if (u['error'] != null) error = u['error'].toString();
    if (u['path'] != null) path = u['path'].toString();
    if (u['title'] != null && u['title'].toString().isNotEmpty) {
      title = u['title'].toString();
    }
    if (u['url'] != null && u['url'].toString().isNotEmpty) {
      url = u['url'].toString();
    }
    if (u['quality'] != null) quality = u['quality'].toString();
  }
}

class JobStore extends ChangeNotifier {
  final Map<String, DownloadJob> _jobs = {};
  StreamSubscription? _sub;

  List<DownloadJob> get jobs {
    final list = _jobs.values.toList();
    list.sort((a, b) => b.id.compareTo(a.id)); // newest first (id = timestamp)
    return list;
  }

  Future<void> init() async {
    // Restore jobs still known by the service (app was closed, service ran on)
    try {
      final existing = await Downloader.getJobs();
      if (existing != null) {
        for (final e in existing) {
          final m = Map<String, dynamic>.from(e as Map);
          final id = m['id'].toString();
          final job = _jobs.putIfAbsent(
            id,
            () => DownloadJob(
              id: id,
              url: (m['url'] ?? '').toString(),
              title: (m['title'] ?? m['url'] ?? '').toString(),
              quality: (m['quality'] ?? '720').toString(),
            ),
          );
          job.applyUpdate(m);
        }
      }
    } catch (_) {}

    _sub = Downloader.progressChannel.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      final m = Map<String, dynamic>.from(event);
      final id = m['id']?.toString();
      if (id == null) return;
      final job = _jobs.putIfAbsent(
        id,
        () => DownloadJob(
          id: id,
          url: (m['url'] ?? '').toString(),
          title: (m['title'] ?? m['url'] ?? '').toString(),
          quality: (m['quality'] ?? '720').toString(),
        ),
      );
      job.applyUpdate(m);
      notifyListeners();
    });
    notifyListeners();
  }

  Future<DownloadJob> enqueue({
    required String url,
    required String quality,
    String? referer,
    String? title,
    String? reuseId,
  }) async {
    final id = reuseId ?? DateTime.now().millisecondsSinceEpoch.toString();
    final job = _jobs.putIfAbsent(
      id,
      () => DownloadJob(
          id: id,
          url: url,
          title: title ?? url,
          quality: quality,
          referer: referer),
    );
    job.status = 'queued';
    job.error = '';
    notifyListeners();
    await Downloader.download(
        id: id, url: url, quality: quality, referer: referer, title: title);
    return job;
  }

  Future<void> cancel(String id) async {
    await Downloader.cancel(id);
  }

  Future<void> retry(String id) async {
    final job = _jobs[id];
    if (job == null) return;
    // Same output filename template + --continue = resumes the .part file
    await enqueue(
      url: job.url,
      quality: job.quality,
      referer: job.referer,
      title: job.title,
      reuseId: id,
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final store = JobStore();

// ---------------------------------------------------------------------------
// App shell
// ---------------------------------------------------------------------------

class VideoGrabberApp extends StatelessWidget {
  const VideoGrabberApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Video Grabber',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF7B2FF7), brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  final _downloaderKey = GlobalKey<_DownloaderPageState>();

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await [
      Permission.notification,
      Permission.storage,
    ].request();
    if (await Permission.manageExternalStorage.isDenied) {
      await Permission.manageExternalStorage.request();
    }
    await store.init();

    final shared = await Downloader.getSharedUrl();
    if (shared != null && shared.isNotEmpty && mounted) {
      final url = _extractUrl(shared);
      if (url != null) {
        setState(() => _index = 1);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _downloaderKey.currentState?.loadUrl(url);
        });
      }
    }
  }

  String? _extractUrl(String text) {
    final m = RegExp(r'https?://\S+').firstMatch(text);
    return m?.group(0);
  }

  void openInDownloader(String url, {String? referer, String? title}) {
    setState(() => _index = 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _downloaderKey.currentState?.loadUrl(url, referer: referer, title: title);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          BrowserPage(onDownloadRequest: openInDownloader),
          DownloaderPage(key: _downloaderKey),
          const DownloadsPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.public), label: 'Browser'),
          NavigationDestination(icon: Icon(Icons.link), label: 'Grab'),
          NavigationDestination(
              icon: Icon(Icons.download), label: 'Downloads'),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Browser + sniffer
// ---------------------------------------------------------------------------

class SniffedMedia {
  final String url;
  final String type;
  SniffedMedia(this.url, this.type);
}

class BrowserPage extends StatefulWidget {
  final void Function(String url, {String? referer, String? title})
      onDownloadRequest;
  const BrowserPage({super.key, required this.onDownloadRequest});

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final _urlCtrl = TextEditingController(text: 'https://www.dailymotion.com');
  InAppWebViewController? _web;
  String _currentUrl = 'https://www.dailymotion.com';
  String _pageTitle = '';
  double _progress = 0;
  final List<SniffedMedia> _sniffed = [];

  final Map<String, String> _shortcuts = const {
    'Dailymotion': 'https://www.dailymotion.com',
    'DramaBox Web': 'https://www.dramaboxdb.com',
    'ReelShort': 'https://www.reelshort.com',
    'GoodShort': 'https://www.goodshort.com',
    'YouTube': 'https://m.youtube.com',
    'TikTok': 'https://www.tiktok.com',
    'Facebook': 'https://m.facebook.com/watch',
  };

  bool _looksLikeMedia(String u) {
    final l = u.toLowerCase();
    if (l.contains('.m3u8')) return true;
    if (l.contains('.mpd')) return true;
    if (l.contains('.mp4') && !l.contains('.mp4.jpg')) return true;
    if (l.contains('googlevideo.com/videoplayback')) return true;
    return false;
  }

  String _mediaType(String u) {
    final l = u.toLowerCase();
    if (l.contains('.m3u8')) return 'HLS stream';
    if (l.contains('.mpd')) return 'DASH stream';
    if (l.contains('.mp4')) return 'MP4 video';
    return 'Video';
  }

  void _addSniffed(String url) {
    if (_sniffed.any((s) => s.url == url)) return;
    setState(() {
      _sniffed.insert(0, SniffedMedia(url, _mediaType(url)));
      if (_sniffed.length > 25) _sniffed.removeLast();
    });
  }

  void _go(String input) {
    var u = input.trim();
    if (u.isEmpty) return;
    if (!u.startsWith('http')) {
      if (u.contains('.') && !u.contains(' ')) {
        u = 'https://$u';
      } else {
        u = 'https://www.google.com/search?q=${Uri.encodeComponent(u)}';
      }
    }
    _web?.loadUrl(urlRequest: URLRequest(url: WebUri(u)));
  }

  void _showSniffedSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text('Videos found on this page',
                    style: Theme.of(ctx).textTheme.titleMedium),
              ),
              const SizedBox(height: 4),
              if (_sniffed.isEmpty)
                ListTile(
                  leading: const Icon(Icons.play_circle_outline),
                  title: const Text('Nothing sniffed yet'),
                  subtitle: const Text(
                      'Press PLAY on the video first, then open this again. '
                      'Or download using the page link below.'),
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final s in _sniffed)
                      ListTile(
                        leading: const Icon(Icons.movie),
                        title: Text(s.type),
                        subtitle: Text(s.url,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.download, size: 20),
                        onTap: () {
                          Navigator.pop(ctx);
                          widget.onDownloadRequest(s.url,
                              referer: _currentUrl, title: _pageTitle);
                        },
                      ),
                    ListTile(
                      leading: const Icon(Icons.language),
                      title: const Text('Use page link (YouTube/TikTok/etc.)'),
                      subtitle: Text(_currentUrl,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () {
                        Navigator.pop(ctx);
                        widget.onDownloadRequest(_currentUrl,
                            title: _pageTitle);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => _web?.goBack(),
                ),
                Expanded(
                  child: TextField(
                    controller: _urlCtrl,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    onSubmitted: _go,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Enter site or search',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24)),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _web?.reload(),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final e in _shortcuts.entries)
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: ActionChip(
                      label: Text(e.key),
                      onPressed: () => _go(e.value),
                    ),
                  ),
              ],
            ),
          ),
          if (_progress < 1)
            LinearProgressIndicator(value: _progress, minHeight: 2),
          Expanded(
            child: Stack(
              children: [
                InAppWebView(
                  initialUrlRequest:
                      URLRequest(url: WebUri('https://www.dailymotion.com')),
                  initialSettings: InAppWebViewSettings(
                    mediaPlaybackRequiresUserGesture: true,
                    useOnLoadResource: true,
                    javaScriptEnabled: true,
                    allowsInlineMediaPlayback: true,
                    mixedContentMode:
                        MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                  ),
                  onWebViewCreated: (c) => _web = c,
                  onLoadStart: (c, url) {
                    setState(() {
                      _currentUrl = url?.toString() ?? _currentUrl;
                      _urlCtrl.text = _currentUrl;
                      _sniffed.clear(); // fresh page, fresh sniff list
                    });
                  },
                  onTitleChanged: (c, title) =>
                      setState(() => _pageTitle = title ?? ''),
                  onProgressChanged: (c, p) =>
                      setState(() => _progress = p / 100),
                  onLoadResource: (c, resource) {
                    final u = resource.url?.toString() ?? '';
                    if (_looksLikeMedia(u)) _addSniffed(u);
                  },
                  onUpdateVisitedHistory: (c, url, _) {
                    setState(() {
                      _currentUrl = url?.toString() ?? _currentUrl;
                      _urlCtrl.text = _currentUrl;
                    });
                  },
                ),
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: Badge(
                    isLabelVisible: _sniffed.isNotEmpty,
                    label: Text('${_sniffed.length}'),
                    child: FloatingActionButton(
                      onPressed: _showSniffedSheet,
                      child: const Icon(Icons.download),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Grab page (paste link / receives from browser)
// ---------------------------------------------------------------------------

class DownloaderPage extends StatefulWidget {
  const DownloaderPage({super.key});
  @override
  State<DownloaderPage> createState() => _DownloaderPageState();
}

class _DownloaderPageState extends State<DownloaderPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final _urlCtrl = TextEditingController();
  String? _referer;
  String? _pageTitle;
  Map? _info;
  bool _loadingInfo = false;
  bool _updating = false;
  String? _error;

  void loadUrl(String url, {String? referer, String? title}) {
    setState(() {
      _urlCtrl.text = url;
      _referer = referer;
      _pageTitle = title;
      _info = null;
      _error = null;
    });
    _fetchInfo();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final t = data?.text?.trim();
    if (t != null && t.isNotEmpty) {
      final m = RegExp(r'https?://\S+').firstMatch(t);
      loadUrl(m?.group(0) ?? t);
    }
  }

  Future<void> _fetchInfo() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _loadingInfo = true;
      _error = null;
      _info = null;
    });
    try {
      final info = await Downloader.getInfo(url, referer: _referer);
      setState(() => _info = info);
    } catch (e) {
      setState(() => _error = 'Could not read this link: $e');
    } finally {
      setState(() => _loadingInfo = false);
    }
  }

  Future<void> _start(String quality) async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    final title =
        (_info?['title'] as String?) ?? _pageTitle ?? url;
    await store.enqueue(
        url: url, quality: quality, referer: _referer, title: title);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Added to downloads: $title'),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _updateEngine() async {
    setState(() => _updating = true);
    try {
      await Downloader.updateEngine();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Engine updated to latest yt-dlp')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Update failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final dur = (_info?['duration'] as num?)?.toInt() ?? 0;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Grab a video',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          const Text(
              'Paste a link (Dailymotion, YouTube, TikTok, Facebook, or any '
              '.m3u8 / .mp4 stream sniffed from the browser).'),
          const SizedBox(height: 16),
          TextField(
            controller: _urlCtrl,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              hintText: 'https://...',
              border: const OutlineInputBorder(),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                      icon: const Icon(Icons.paste), onPressed: _paste),
                  IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _urlCtrl.clear();
                        setState(() {
                          _info = null;
                          _referer = null;
                          _pageTitle = null;
                          _error = null;
                        });
                      }),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _loadingInfo ? null : _fetchInfo,
            icon: _loadingInfo
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.search),
            label: const Text('Check video'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!,
                    style: TextStyle(
                        color:
                            Theme.of(context).colorScheme.onErrorContainer)),
              ),
            ),
          ],
          if (_info != null) ...[
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: (_info!['thumbnail'] is String &&
                        (_info!['thumbnail'] as String).startsWith('http'))
                    ? Image.network(_info!['thumbnail'],
                        width: 72, fit: BoxFit.cover, errorBuilder:
                            (_, __, ___) => const Icon(Icons.movie))
                    : const Icon(Icons.movie),
                title: Text(_info!['title']?.toString() ?? 'Video'),
                subtitle: Text([
                  if (_info!['uploader'] != null) _info!['uploader'].toString(),
                  if (dur > 0)
                    '${(dur ~/ 3600) > 0 ? '${dur ~/ 3600}h ' : ''}'
                        '${(dur % 3600) ~/ 60}m ${dur % 60}s',
                ].join(' • ')),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                    onPressed: () => _start('720'),
                    child: const Text('720p')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                    onPressed: () => _start('1080'),
                    child: const Text('1080p')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                    onPressed: () => _start('mp3'),
                    child: const Text('MP3')),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.battery_saver),
            title: const Text('Allow background downloads'),
            subtitle: const Text(
                'Recommended for 1-2 hour videos: stops Android from '
                'killing the download to save battery.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final ok = await Downloader.requestBatteryExemption();
              if (ok && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Already allowed - you are good!')));
              }
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: _updating
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.system_update_alt),
            title: const Text('Update download engine'),
            subtitle:
                const Text('If a site stops working, update yt-dlp here.'),
            onTap: _updating ? null : _updateEngine,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Downloads page
// ---------------------------------------------------------------------------

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});
  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  @override
  void initState() {
    super.initState();
    store.addListener(_onChange);
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    store.removeListener(_onChange);
    super.dispose();
  }

  String _etaText(int eta) {
    if (eta <= 0) return '';
    final h = eta ~/ 3600, m = (eta % 3600) ~/ 60, s = eta % 60;
    if (h > 0) return '${h}h ${m}m left';
    if (m > 0) return '${m}m ${s}s left';
    return '${s}s left';
  }

  @override
  Widget build(BuildContext context) {
    final jobs = store.jobs;
    return SafeArea(
      child: jobs.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No downloads yet.\n\nSniff a video in the Browser tab or '
                  'paste a link in the Grab tab.\n\nFiles are saved to '
                  'Downloads/VideoGrabber.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: jobs.length,
              itemBuilder: (ctx, i) {
                final j = jobs[i];
                final active =
                    j.status == 'downloading' || j.status == 'queued';
                Color statusColor;
                IconData statusIcon;
                switch (j.status) {
                  case 'done':
                    statusColor = Colors.greenAccent;
                    statusIcon = Icons.check_circle;
                    break;
                  case 'failed':
                    statusColor = Colors.redAccent;
                    statusIcon = Icons.error;
                    break;
                  case 'cancelled':
                    statusColor = Colors.orangeAccent;
                    statusIcon = Icons.cancel;
                    break;
                  case 'downloading':
                    statusColor = Colors.lightBlueAccent;
                    statusIcon = Icons.downloading;
                    break;
                  default:
                    statusColor = Colors.grey;
                    statusIcon = Icons.schedule;
                }
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(statusIcon, color: statusColor, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(j.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                            ),
                            Text(j.quality == 'mp3' ? 'MP3' : '${j.quality}p',
                                style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (j.status == 'downloading') ...[
                          LinearProgressIndicator(
                              value:
                                  j.progress > 0 ? j.progress / 100 : null),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('${j.progress.toStringAsFixed(1)}%'),
                              Text(_etaText(j.eta)),
                            ],
                          ),
                        ],
                        if (j.status == 'queued')
                          const Text('Waiting in queue...'),
                        if (j.status == 'done')
                          Text('Saved in Downloads/VideoGrabber',
                              style: Theme.of(context).textTheme.bodySmall),
                        if (j.status == 'failed')
                          Text(j.error,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: Colors.red.shade200, fontSize: 12)),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (active)
                              TextButton.icon(
                                onPressed: () => store.cancel(j.id),
                                icon: const Icon(Icons.stop, size: 18),
                                label: const Text('Cancel'),
                              ),
                            if (j.status == 'failed' ||
                                j.status == 'cancelled')
                              TextButton.icon(
                                onPressed: () => store.retry(j.id),
                                icon: const Icon(Icons.replay, size: 18),
                                label: const Text('Resume'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
