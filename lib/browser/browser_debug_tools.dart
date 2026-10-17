part of 'browser_tools.dart';

// The agents' DevTools: a shared tab's console, network and performance,
// and the conditions it runs in. What the console and network kept comes
// from the first time BaoCode used the tab (see browser_records.dart).

final _debugTools = [
  ClaudeSdkTool(
    name: 'browser_console',
    description:
        "A shared tab's console since BaoCode first used it: console calls, "
        'uncaught exceptions, and the browser\'s own messages (blocked '
        'requests, CORS, CSP), oldest first.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'tabId': BrowserTools._tabId,
        'level': {
          'type': 'string',
          'enum': ['all', 'warning', 'error'],
          'description': 'warning: warnings and errors. Default all.',
        },
        'limit': {'type': 'integer', 'description': 'The last n. Default 100.'},
        'clear': {
          'type': 'boolean',
          'description': 'Forget them after reading.',
        },
      },
      'required': ['tabId'],
    },
    run: (input, call) async {
      final tab = BrowserTab(BrowserTools._browser(), input['tabId'] as int);
      final records = BrowserRecords.instance;
      final level = input['level'] as String? ?? 'all';
      final entries = records
          .console(tab)
          .where(
            (e) => switch (level) {
              'error' => e.level == 'error',
              'warning' => e.level == 'error' || e.level == 'warning',
              _ => true,
            },
          )
          .toList();
      if (input['clear'] == true) records.clearConsole(tab);
      if (entries.isEmpty) return 'Nothing logged.';
      final limit = input['limit'] as int? ?? 100;
      final shown = entries.length > limit
          ? entries.sublist(entries.length - limit)
          : entries;
      String time(DateTime t) =>
          '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}:'
          '${t.second.toString().padLeft(2, '0')}.'
          '${t.millisecond.toString().padLeft(3, '0')}';
      return [
        if (shown.length < entries.length)
          'The last ${shown.length} of ${entries.length}:',
        for (final e in shown)
          '[${time(e.time)}] ${e.level}: ${_clip(e.text, 2000)}'
              '${e.url == null || e.url!.isEmpty ? '' : ' (${e.url}${e.line == null ? '' : ':${e.line}'})'}',
      ].join('\n');
    },
  ),
  ClaudeSdkTool(
    name: 'browser_network',
    description:
        "Lists the requests of a shared tab's page since BaoCode first used "
        'it, oldest first: id, method, status, type, size, time, URL. Read '
        'one with browser_request.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'tabId': BrowserTools._tabId,
        'url': {'type': 'string', 'description': 'Those whose URL has it.'},
        'type': {
          'type': 'string',
          'description':
              'Document, XHR, Fetch, Script, Stylesheet, Image, Font, Media, '
              'WebSocket, Other.',
        },
        'failed': {
          'type': 'boolean',
          'description': 'Those that failed or got a status of 400 or more.',
        },
        'limit': {'type': 'integer', 'description': 'The last n. Default 50.'},
        'clear': {
          'type': 'boolean',
          'description': 'Forget them after reading.',
        },
      },
      'required': ['tabId'],
    },
    run: (input, call) async {
      final tab = BrowserTab(BrowserTools._browser(), input['tabId'] as int);
      final records = BrowserRecords.instance;
      final url = input['url'] as String?;
      final type = (input['type'] as String?)?.toLowerCase();
      final failed = input['failed'] == true;
      final requests = records
          .requests(tab)
          .where(
            (r) =>
                (url == null || r.url.contains(url)) &&
                (type == null || r.type.toLowerCase() == type) &&
                (!failed || r.failure != null || (r.status ?? 0) >= 400),
          )
          .toList();
      if (input['clear'] == true) records.clearRequests(tab);
      if (requests.isEmpty) return 'No request.';
      final limit = input['limit'] as int? ?? 50;
      final shown = requests.length > limit
          ? requests.sublist(requests.length - limit)
          : requests;
      return [
        if (shown.length < requests.length)
          'The last ${shown.length} of ${requests.length}:',
        for (final r in shown)
          [
            r.id,
            r.method,
            // A response's status over a failure after it (its body let go).
            r.status?.toString() ?? r.failure ?? 'pending',
            r.type,
            if (r.fromCache) '(cache)' else _bytes(r.size),
            if (r.duration case final ms?) '$ms ms' else '…',
            _clip(r.url, 300),
          ].join(' '),
      ].join('\n');
    },
  ),
  ClaudeSdkTool(
    name: 'browser_request',
    description:
        'A request of a shared tab (its id, from browser_network): its '
        'headers, body, and the response: status, headers, body (text, '
        'or the image).',
    inputSchema: {
      'type': 'object',
      'properties': {
        'tabId': BrowserTools._tabId,
        'id': {'type': 'string'},
      },
      'required': ['tabId', 'id'],
    },
    run: (input, call) async {
      final browser = BrowserTools._browser();
      final tabId = input['tabId'] as int;
      final id = input['id'] as String;
      final r = BrowserRecords.instance.request(BrowserTab(browser, tabId), id);
      if (r == null) {
        throw StateError('No request $id: list them with browser_network.');
      }
      String headers(Map<String, Object?>? map) => map == null || map.isEmpty
          ? '  (none)'
          : [for (final e in map.entries) '  ${e.key}: ${e.value}'].join('\n');
      var postData = r.postData;
      if (r.hasPostData && postData == null) {
        try {
          final result = await browser.cdp(
            tabId,
            'Network.getRequestPostData',
            {'requestId': id},
          );
          postData = result['postData'] as String?;
        } on Object {
          postData = '(not kept)';
        }
      }
      final text = [
        '${r.method} ${r.url}',
        'Type: ${r.type}',
        'Request headers:',
        headers(r.requestHeaders),
        if (postData != null) 'Request body:\n${_clip(postData, 20000)}',
        '',
        if (r.failure != null) 'Failed: ${r.failure}',
        if (r.status != null) 'Status: ${r.status} ${r.statusText ?? ''}',
        if (r.duration case final ms?) 'Time: $ms ms, ${_bytes(r.size)}',
        if (r.responseHeaders != null) 'Response headers:',
        if (r.responseHeaders != null) headers(r.responseHeaders),
      ];
      if (r.failure != null || r.status == null || !r.finished) {
        return text.join('\n');
      }
      try {
        final body = await browser.cdp(tabId, 'Network.getResponseBody', {
          'requestId': id,
        });
        final data = body['body'] as String? ?? '';
        if (body['base64Encoded'] == true) {
          final mime = r.mimeType ?? '';
          if (const [
            'image/png',
            'image/jpeg',
            'image/gif',
            'image/webp',
          ].contains(mime)) {
            return [
              claudeSdkText('${text.join('\n')}\nResponse body:'),
              claudeSdkImage(data, mime),
            ];
          }
          text.add('Response body: binary, ${_bytes(data.length * 3 ~/ 4)}.');
        } else {
          text.add('Response body:\n${_clip(data, 30000)}');
        }
      } on Object {
        text.add('Response body: not kept by the browser.');
      }
      return text.join('\n');
    },
  ),
  ClaudeSdkTool(
    name: 'browser_performance',
    description:
        "Records a shared tab's performance, as DevTools' Performance panel "
        'does: "reload" (the default) reloads the page and records its '
        'load; "start" begins a recording and "stop" ends it, for what you '
        'do in between. Returns Web Vitals (LCP, CLS, FCP, TTFB), the main '
        "thread's busy time by kind, its long tasks and what ran in them, "
        'the slowest requests, and the path of the trace saved, which the '
        'user can open in DevTools.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'tabId': BrowserTools._tabId,
        'action': {
          'type': 'string',
          'enum': ['reload', 'start', 'stop'],
        },
      },
      'required': ['tabId'],
    },
    run: (input, call) async {
      final browser = BrowserTools._browser();
      final tab = BrowserTab(browser, input['tabId'] as int);
      switch (input['action'] as String? ?? 'reload') {
        case 'start':
          await _Trace.start(tab);
          return 'Recording. Stop with action "stop".';
        case 'stop':
          final trace = _Trace.of(tab);
          if (trace == null) throw StateError('Not recording: start first.');
          return trace.stop();
        default:
          final trace = await _Trace.start(tab);
          await BrowserTools._loading(
            browser,
            tab.tabId,
            () => browser.cdp(tab.tabId, 'Page.reload'),
            timeout: const Duration(seconds: 30),
          );
          // What follows the load: late scripts, layout shifts.
          await Future<void>.delayed(const Duration(seconds: 2));
          return trace.stop();
      }
    },
  ),
  ClaudeSdkTool(
    name: 'browser_emulate',
    description:
        'Makes a shared tab run as on a slower machine or network, or a '
        'phone: kept while BaoCode uses the tab. "none" undoes each.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'tabId': BrowserTools._tabId,
        'cpu': {
          'type': 'number',
          'description': 'How many times slower (4: a mid phone). 1: none.',
        },
        'network': {
          'type': 'string',
          'enum': ['none', 'offline', 'slow3g', 'fast3g', 'fast4g'],
        },
        'device': {
          'type': 'string',
          'enum': ['none', 'phone', 'tablet'],
        },
      },
      'required': ['tabId'],
    },
    run: (input, call) async {
      final browser = BrowserTools._browser();
      final tabId = input['tabId'] as int;
      final done = <String>[];
      if (input['cpu'] case final num rate) {
        await browser.cdp(tabId, 'Emulation.setCPUThrottlingRate', {
          'rate': rate < 1 ? 1 : rate,
        });
        done.add(rate <= 1 ? 'CPU: as is' : 'CPU: ${rate}x slower');
      }
      if (input['network'] case final String network) {
        // DevTools' presets: latency (ms), down and up (bytes a second).
        final (latency, down, up) = switch (network) {
          'slow3g' => (2000, 50000, 50000),
          'fast3g' => (563, 180000, 84375),
          'fast4g' => (165, 1012500, 168750),
          _ => (0, -1, -1),
        };
        await browser.cdp(tabId, 'Network.emulateNetworkConditions', {
          'offline': network == 'offline',
          'latency': latency,
          'downloadThroughput': down,
          'uploadThroughput': up,
        });
        done.add('Network: $network');
      }
      if (input['device'] case final String device) {
        if (device == 'none') {
          await browser.cdp(tabId, 'Emulation.clearDeviceMetricsOverride');
          await browser.cdp(tabId, 'Emulation.setTouchEmulationEnabled', {
            'enabled': false,
          });
        } else {
          final phone = device == 'phone';
          await browser.cdp(tabId, 'Emulation.setDeviceMetricsOverride', {
            'width': phone ? 390 : 820,
            'height': phone ? 844 : 1180,
            'deviceScaleFactor': phone ? 3 : 2,
            'mobile': true,
          });
          await browser.cdp(tabId, 'Emulation.setTouchEmulationEnabled', {
            'enabled': true,
            'maxTouchPoints': 5,
          });
        }
        done.add('Device: $device');
      }
      return done.isEmpty ? 'Nothing asked.' : done.join('\n');
    },
  ),
];

String _clip(String text, int max) => text.length > max
    ? '${text.substring(0, max)}… (${text.length} chars)'
    : text;

String _bytes(int? bytes) => switch (bytes) {
  null => '?',
  < 1024 => '$bytes B',
  < 1024 * 1024 => '${(bytes / 1024).toStringAsFixed(1)} kB',
  _ => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB',
};

/// A recording of a tab's: its trace events as they come, then what they
/// say.
class _Trace {
  _Trace._(this.tab);

  final BrowserTab tab;
  final List<Object?> _events = [];
  final _complete = Completer<void>();
  StreamSubscription<BrowserEvent>? _subscription;
  late final double _started;

  static final Map<BrowserTab, _Trace> _recording = {};

  static _Trace? of(BrowserTab tab) => _recording[tab];

  /// The categories of DevTools' Performance panel.
  static const _categories = [
    '-*',
    'blink.console',
    'blink.user_timing',
    'devtools.timeline',
    'disabled-by-default-devtools.timeline',
    'disabled-by-default-devtools.timeline.frame',
    'disabled-by-default-devtools.timeline.stack',
    'disabled-by-default-v8.cpu_profiler',
    'latencyInfo',
    'loading',
    'toplevel',
    'v8.execute',
  ];

  static Future<_Trace> start(BrowserTab tab) async {
    if (_recording.remove(tab) case final old?) {
      await old._end().catchError((Object _) {});
    }
    final trace = _Trace._(tab);
    trace._subscription = BrowserBridge.instance.events.listen((event) {
      if (event.event != 'cdp' ||
          !identical(event.connection, tab.browser) ||
          event.tabId != tab.tabId) {
        return;
      }
      final params = event.message['params'] as Map?;
      switch (event.message['method']) {
        case 'Tracing.dataCollected':
          trace._events.addAll(params?['value'] as List? ?? const []);
        case 'Tracing.tracingComplete':
          if (!trace._complete.isCompleted) trace._complete.complete();
      }
    });
    trace._started = DateTime.now().millisecondsSinceEpoch / 1000;
    await tab.browser.cdp(tab.tabId, 'Tracing.start', {
      'transferMode': 'ReportEvents',
      'traceConfig': {
        'recordMode': 'recordAsMuchAsPossible',
        'includedCategories': _categories.where((c) => c != '-*').toList(),
        'excludedCategories': ['*'],
      },
    });
    _recording[tab] = trace;
    return trace;
  }

  Future<void> _end() async {
    try {
      await tab.browser.cdp(tab.tabId, 'Tracing.end');
      await _complete.future.timeout(const Duration(seconds: 30));
    } finally {
      await _subscription?.cancel();
    }
  }

  Future<String> stop() async {
    _recording.remove(tab);
    await _end();
    final browser = tab.browser;
    final metrics = await browser.cdp(tab.tabId, 'Performance.getMetrics');
    final vitals = await BrowserTools._evaluate(
      browser,
      tab.tabId,
      _vitalsScript,
    );
    final file = await _save();
    return [
      ..._summarizeVitals(vitals),
      '',
      ..._summarizeMetrics(metrics),
      '',
      ..._summarizeMainThread(),
      '',
      ..._summarizeRequests(),
      '',
      'Trace: ${file.path} (${_bytes(file.lengthSync())}; DevTools ›'
          ' Performance › Load profile opens it)',
    ].join('\n');
  }

  Future<File> _save() async {
    final folder = Directory(
      p.join(Directory.systemTemp.path, 'baocode-traces'),
    )..createSync(recursive: true);
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final file = File(p.join(folder.path, 'trace-$stamp.json'));
    await file.writeAsString(jsonEncode({'traceEvents': _events}));
    return file;
  }

  static const _vitalsScript = r'''
new Promise((done) => {
  const out = {};
  try {
    new PerformanceObserver((list) => {
      const entries = list.getEntries();
      const last = entries[entries.length - 1];
      if (last) { out.lcp = last.startTime; out.lcpElement = last.element ? last.element.tagName.toLowerCase() + (last.element.id ? '#' + last.element.id : '') : (last.url || ''); }
    }).observe({ type: 'largest-contentful-paint', buffered: true });
  } catch (e) {}
  let cls = 0;
  try {
    new PerformanceObserver((list) => {
      for (const e of list.getEntries()) if (!e.hadRecentInput) cls += e.value;
    }).observe({ type: 'layout-shift', buffered: true });
  } catch (e) {}
  const nav = performance.getEntriesByType('navigation')[0];
  const fcp = performance.getEntriesByName('first-contentful-paint')[0];
  setTimeout(() => done({
    lcp: out.lcp, lcpElement: out.lcpElement, cls,
    fcp: fcp && fcp.startTime,
    ttfb: nav && nav.responseStart,
    domContentLoaded: nav && nav.domContentLoadedEventEnd,
    load: nav && nav.loadEventEnd,
    transferSize: nav && nav.transferSize,
    resources: performance.getEntriesByType('resource').length,
  }), 100);
})
''';

  static String _ms(Object? value) =>
      value is num ? '${value.round()} ms' : '—';

  static List<String> _summarizeVitals(Object? value) {
    final v = (value as Map?)?.cast<String, Object?>() ?? {};
    String rate(num? value, num good, num poor) => value == null
        ? ''
        : value <= good
        ? ' (good)'
        : value <= poor
        ? ' (needs improvement)'
        : ' (poor)';
    final cls = v['cls'] as num?;
    return [
      'Web Vitals (of the page as loaded):',
      '  LCP: ${_ms(v['lcp'])}${rate(v['lcp'] as num?, 2500, 4000)}'
          '${v['lcpElement'] is String && (v['lcpElement'] as String).isNotEmpty ? ' — ${v['lcpElement']}' : ''}',
      '  CLS: ${cls == null ? '—' : cls.toStringAsFixed(3)}${rate(cls, 0.1, 0.25)}',
      '  FCP: ${_ms(v['fcp'])}${rate(v['fcp'] as num?, 1800, 3000)}',
      '  TTFB: ${_ms(v['ttfb'])}${rate(v['ttfb'] as num?, 800, 1800)}',
      '  DOMContentLoaded: ${_ms(v['domContentLoaded'])}, load: ${_ms(v['load'])}',
      '  Resources: ${v['resources'] ?? '—'}',
    ];
  }

  static List<String> _summarizeMetrics(Map<String, Object?> result) {
    final metrics = {
      for (final m in (result['metrics'] as List? ?? const []).cast<Map>())
        m['name'] as String: m['value'] as num,
    };
    String seconds(String name) =>
        metrics[name] == null ? '—' : '${(metrics[name]! * 1000).round()} ms';
    return [
      'Page now:',
      '  JS heap: ${_bytes(metrics['JSHeapUsedSize']?.toInt())} used of '
          '${_bytes(metrics['JSHeapTotalSize']?.toInt())}',
      '  DOM nodes: ${metrics['Nodes']?.toInt() ?? '—'}, listeners: '
          '${metrics['JSEventListeners']?.toInt() ?? '—'}, frames: '
          '${metrics['Frames']?.toInt() ?? '—'}',
      '  Since the page opened: script ${seconds('ScriptDuration')}, layout '
          '${seconds('LayoutDuration')} (${metrics['LayoutCount']?.toInt() ?? '—'}x), '
          'style ${seconds('RecalcStyleDuration')} '
          '(${metrics['RecalcStyleCount']?.toInt() ?? '—'}x)',
    ];
  }

  /// What the page's main thread did: busy time by kind, and its long
  /// tasks (50 ms or more), each with what took longest in it.
  List<String> _summarizeMainThread() {
    final events = _events.whereType<Map>().toList();
    // The page's main thread: the renderer's busiest.
    final mains = <(int, int)>{
      for (final e in events)
        if (e['ph'] == 'M' &&
            e['name'] == 'thread_name' &&
            (e['args'] as Map?)?['name'] == 'CrRendererMain')
          (e['pid'] as int, e['tid'] as int),
    };
    final busy = <(int, int), num>{};
    for (final e in events) {
      if (e['ph'] != 'X' || e['name'] != 'RunTask') continue;
      final thread = (e['pid'] as int, e['tid'] as int);
      if (!mains.contains(thread)) continue;
      busy[thread] = (busy[thread] ?? 0) + (e['dur'] as num? ?? 0);
    }
    if (busy.isEmpty) return ['Main thread: nothing recorded.'];
    final main = busy.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    final onMain = [
      for (final e in events)
        if (e['ph'] == 'X' &&
            e['pid'] == main.$1 &&
            e['tid'] == main.$2 &&
            e['dur'] is num)
          e,
    ]..sort((a, b) => (a['ts'] as num).compareTo(b['ts'] as num));

    const kinds = {
      'Scripting': {
        'FunctionCall',
        'EvaluateScript',
        'v8.compile',
        'v8.compileModule',
        'EventDispatch',
        'TimerFire',
        'FireAnimationFrame',
        'FireIdleCallback',
        'RunMicrotasks',
        'V8.GCScavenger',
        'MajorGC',
        'MinorGC',
      },
      'Rendering': {
        'Layout',
        'UpdateLayoutTree',
        'PrePaint',
        'Paint',
        'Layerize',
        'Commit',
        'ScrollLayer',
        'IntersectionObserverController::computeIntersections',
      },
      'Parsing': {'ParseHTML', 'ParseAuthorStyleSheet'},
    };
    String? kindOf(String name) {
      for (final MapEntry(:key, :value) in kinds.entries) {
        if (value.contains(name)) return key;
      }
      return null;
    }

    // Each kind's outermost events alone: not counted twice nested.
    final totals = <String, num>{};
    num covered = 0;
    for (final e in onMain) {
      final kind = kindOf(e['name'] as String);
      if (kind == null) continue;
      final ts = e['ts'] as num;
      if (ts < covered) continue;
      totals[kind] = (totals[kind] ?? 0) + (e['dur'] as num);
      covered = ts + (e['dur'] as num);
    }
    String ms(num micros) => '${(micros / 1000).round()} ms';
    final tasks = [
      for (final e in onMain)
        if (e['name'] == 'RunTask' && (e['dur'] as num) >= 50000) e,
    ]..sort((a, b) => (b['dur'] as num).compareTo(a['dur'] as num));
    final first = onMain.first['ts'] as num;

    Map data(Map e) => ((e['args'] as Map?)?['data'] as Map?) ?? const {};
    bool located(Map e) {
      final d = data(e);
      return (d['url'] is String && (d['url'] as String).isNotEmpty) ||
          (d['functionName'] is String &&
              (d['functionName'] as String).isNotEmpty);
    }

    /// What took longest in [task]: the longest of the code it ran that
    /// says where it is (a script's URL, a function), else of any kind.
    String what(Map task) {
      final start = task['ts'] as num;
      final end = start + (task['dur'] as num);
      Map? longest;
      Map? located0;
      for (final e in onMain) {
        final ts = e['ts'] as num;
        if (ts < start || ts >= end || identical(e, task)) continue;
        if (kindOf(e['name'] as String) == null) continue;
        final dur = e['dur'] as num;
        if (longest == null || dur > (longest['dur'] as num)) longest = e;
        if (located(e) &&
            (located0 == null || dur > (located0['dur'] as num))) {
          located0 = e;
        }
      }
      longest = located0 ?? longest;
      if (longest == null) return '';
      final data0 = data(longest);
      final where = [
        if (data0['functionName'] case final String f when f.isNotEmpty) f,
        if (data0['url'] case final String u when u.isNotEmpty)
          // The trace's lines count from 1.
          '${_clip(u, 120)}${data0['lineNumber'] is int ? ':${data0['lineNumber']}' : ''}',
        if (data0['type'] case final String t when t.isNotEmpty) t,
      ].join(' ');
      return ' — ${longest['name']} ${ms(longest['dur'] as num)}'
          '${where.isEmpty ? '' : ' ($where)'}';
    }

    return [
      'Main thread: busy ${ms(busy[main]!)}; '
          '${['Scripting', 'Rendering', 'Parsing'].map((k) => '${k.toLowerCase()} ${ms(totals[k] ?? 0)}').join(', ')}',
      if (tasks.isEmpty) '  No long task (50 ms or more).',
      if (tasks.isNotEmpty)
        '  Long tasks (${tasks.length}; total blocking '
            '${ms(tasks.fold<num>(0, (sum, t) => sum + (t['dur'] as num) - 50000))}):',
      for (final task in tasks.take(10))
        '  at ${ms((task['ts'] as num) - first)}: ${ms(task['dur'] as num)}'
            '${what(task)}',
    ];
  }

  List<String> _summarizeRequests() {
    final requests = BrowserRecords.instance
        .requests(tab)
        .where((r) => r.duration != null)
        .toList();
    // Those of the recording: the browser's clock is not the wall's, so by
    // the order they came in, the last of them (since it started).
    final during = requests.where((r) => r.wall >= _started).toList()
      ..sort((a, b) => b.duration!.compareTo(a.duration!));
    if (during.isEmpty) return ['Requests: none recorded.'];
    final total = during.fold<int>(0, (sum, r) => sum + (r.size ?? 0));
    return [
      'Requests: ${during.length}, ${_bytes(total)} over the network. '
          'Slowest:',
      for (final r in during.take(5))
        '  ${r.duration} ms ${r.status ?? r.failure ?? ''} ${r.type} '
            '${_bytes(r.size)} ${_clip(r.url, 200)} (${r.id})',
    ];
  }
}
