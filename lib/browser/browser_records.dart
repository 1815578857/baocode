import 'dart:async';

import 'browser_bridge.dart';

/// What the shared tabs' pages log and load, kept from the first time
/// BaoCode uses each (its console's and network's domains enabled then),
/// for agents to look at afterwards: as DevTools' Console and Network keep
/// them once open.
class BrowserRecords {
  BrowserRecords._() {
    BrowserBridge.instance.events.listen(_received);
  }

  static final instance = BrowserRecords._();

  static const _maxConsole = 500;
  static const _maxRequests = 1000;

  final Map<BrowserTab, _TabRecords> _tabs = {};

  /// Starts keeping [tab]'s, if not yet: before what an agent does there.
  Future<void> watch(BrowserTab tab) async {
    final records = _tabs.putIfAbsent(tab, _TabRecords.new);
    if (records.watching != null) return records.watching;
    final watching = () async {
      for (final (method, params) in [
        ('Network.enable', {'maxPostDataSize': 65536}),
        ('Runtime.enable', const <String, Object?>{}),
        ('Log.enable', const <String, Object?>{}),
        ('Page.enable', const <String, Object?>{}),
        ('Performance.enable', const <String, Object?>{}),
      ]) {
        await tab.browser.cdp(tab.tabId, method, params);
      }
    }();
    records.watching = watching;
    try {
      await watching;
    } on Object {
      // Asked again next time.
      records.watching = null;
      rethrow;
    }
  }

  List<ConsoleEntry> console(BrowserTab tab) => [...?_tabs[tab]?.console];

  List<NetworkRequest> requests(BrowserTab tab) => [
    ...?_tabs[tab]?.requests.values,
  ];

  NetworkRequest? request(BrowserTab tab, String id) =>
      _tabs[tab]?.requests[id];

  void clearConsole(BrowserTab tab) => _tabs[tab]?.console.clear();

  void clearRequests(BrowserTab tab) => _tabs[tab]?.requests.clear();

  void _received(BrowserEvent event) {
    final tabId = event.tabId;
    if (tabId == null) return;
    final tab = BrowserTab(event.connection, tabId);
    switch (event.event) {
      case 'closed' || 'unshared':
        _tabs.remove(tab);
        return;
      case 'detached':
        // Enabled again as it is used again.
        _tabs[tab]?.watching = null;
        return;
      case 'cdp':
        break;
      default:
        return;
    }
    final records = _tabs[tab];
    if (records == null) return;
    final params =
        (event.message['params'] as Map?)?.cast<String, Object?>() ?? {};
    switch (event.message['method']) {
      case 'Runtime.consoleAPICalled':
        records.log(ConsoleEntry.fromConsole(params));
      case 'Runtime.exceptionThrown':
        records.log(ConsoleEntry.fromException(params));
      case 'Log.entryAdded':
        records.log(ConsoleEntry.fromLog(params));
      case 'Network.requestWillBeSent':
        final id = params['requestId'] as String;
        final redirected = records.requests[id];
        if (redirected != null && params['redirectResponse'] is Map) {
          // A redirect: the one before keeps its id's own, apart.
          redirected.respond(
            (params['redirectResponse'] as Map).cast<String, Object?>(),
          );
          records.requests.remove(id);
          records.add(redirected..id = '$id.r${records.redirects++}');
        }
        records.add(NetworkRequest.fromSent(params));
      case 'Network.responseReceived':
        final request = records.requests[params['requestId']];
        request?.type = params['type'] as String? ?? request.type;
        request?.respond((params['response'] as Map).cast<String, Object?>());
      case 'Network.loadingFinished':
        records.requests[params['requestId']]
          ?..finished = true
          ..end = (params['timestamp'] as num?)?.toDouble()
          ..size = (params['encodedDataLength'] as num?)?.toInt();
      case 'Network.loadingFailed':
        records.requests[params['requestId']]
          ?..finished = true
          ..end = (params['timestamp'] as num?)?.toDouble()
          ..failure = params['canceled'] == true
              ? 'canceled'
              : params['errorText'] as String? ?? 'failed';
    }
  }
}

class _TabRecords {
  Future<void>? watching;
  final List<ConsoleEntry> console = [];
  final Map<String, NetworkRequest> requests = {};
  int redirects = 0;

  void log(ConsoleEntry entry) {
    console.add(entry);
    if (console.length > BrowserRecords._maxConsole) console.removeAt(0);
  }

  void add(NetworkRequest request) {
    requests[request.id] = request;
    if (requests.length > BrowserRecords._maxRequests) {
      requests.remove(requests.keys.first);
    }
  }
}

/// A line of a page's console: a `console.…` call's, an exception's, the
/// browser's own (a blocked request, a violation).
class ConsoleEntry {
  ConsoleEntry({
    required this.level,
    required this.text,
    this.url,
    this.line,
    required this.time,
  });

  /// `log`, `info`, `warning`, `error`, `debug`.
  final String level;
  final String text;
  final String? url;
  final int? line;
  final DateTime time;

  /// One-based, as the console shows it (the protocol's are zero-based).
  static int? _line(Object? line) => line is int ? line + 1 : null;

  static DateTime _time(Object? millis) => millis is num
      ? DateTime.fromMillisecondsSinceEpoch(millis.round())
      : DateTime.now();

  factory ConsoleEntry.fromConsole(Map<String, Object?> params) {
    final args = (params['args'] as List? ?? const []).cast<Map>();
    final frames = ((params['stackTrace'] as Map?)?['callFrames'] as List?)
        ?.cast<Map>();
    final type = params['type'] as String? ?? 'log';
    return ConsoleEntry(
      level: switch (type) {
        'warning' => 'warning',
        'error' || 'assert' => 'error',
        'debug' => 'debug',
        'info' => 'info',
        _ => 'log',
      },
      text: args.map(_remote).join(' '),
      url: frames?.firstOrNull?['url'] as String?,
      line: _line(frames?.firstOrNull?['lineNumber']),
      time: _time(params['timestamp']),
    );
  }

  factory ConsoleEntry.fromException(Map<String, Object?> params) {
    final details = (params['exceptionDetails'] as Map).cast<String, Object?>();
    final exception = details['exception'] as Map?;
    return ConsoleEntry(
      level: 'error',
      text:
          '${exception?['description'] ?? details['text'] ?? 'Uncaught exception'}',
      url: details['url'] as String?,
      line: _line(details['lineNumber']),
      time: _time(params['timestamp']),
    );
  }

  factory ConsoleEntry.fromLog(Map<String, Object?> params) {
    final entry = (params['entry'] as Map).cast<String, Object?>();
    return ConsoleEntry(
      level: switch (entry['level']) {
        'warning' => 'warning',
        'error' => 'error',
        'verbose' => 'debug',
        _ => 'info',
      },
      text: '${entry['text'] ?? ''}',
      url: entry['url'] as String?,
      line: _line(entry['lineNumber']),
      time: _time(entry['timestamp']),
    );
  }

  /// A logged value, as the console writes it in a line.
  static String _remote(Map arg) {
    if (arg.containsKey('value')) {
      final value = arg['value'];
      return value is String ? value : '$value';
    }
    if (arg['unserializableValue'] case final String value) return value;
    if (arg['preview'] case final Map preview) return _preview(preview);
    return '${arg['description'] ?? arg['className'] ?? arg['type']}';
  }

  /// An object's preview, as the console shows it folded: `{n: 1, s: 'a'}`,
  /// `[1, 2]`.
  static String _preview(Map preview) {
    final properties = (preview['properties'] as List? ?? const []).cast<Map>();
    final array = preview['subtype'] == 'array';
    final items = [
      for (final p in properties)
        array
            ? '${p['value'] ?? p['type']}'
            : '${p['name']}: ${p['type'] == 'string' ? "'${p['value']}'" : p['value'] ?? p['type']}',
      if (preview['overflow'] == true) '…',
    ].join(', ');
    return array ? '[$items]' : '{$items}';
  }
}

/// A request a page made, and what came back.
class NetworkRequest {
  NetworkRequest._({
    required this.id,
    required this.method,
    required this.url,
    required this.type,
    required this.start,
    required this.wall,
    required this.requestHeaders,
    required this.hasPostData,
    this.postData,
  });

  factory NetworkRequest.fromSent(Map<String, Object?> params) {
    final request = (params['request'] as Map).cast<String, Object?>();
    return NetworkRequest._(
      id: params['requestId'] as String,
      method: request['method'] as String? ?? 'GET',
      url: request['url'] as String? ?? '',
      type: params['type'] as String? ?? 'Other',
      start: (params['timestamp'] as num?)?.toDouble() ?? 0,
      wall:
          (params['wallTime'] as num?)?.toDouble() ??
          DateTime.now().millisecondsSinceEpoch / 1000,
      requestHeaders: (request['headers'] as Map? ?? const {})
          .cast<String, Object?>(),
      hasPostData: request['hasPostData'] == true,
      postData: request['postData'] as String?,
    );
  }

  /// The browser's, as DevTools has it (a redirect's with a suffix).
  String id;
  final String method;
  final String url;

  /// DevTools' resource type: `Document`, `XHR`, `Fetch`, `Script`…
  String type;

  /// The browser's clock, seconds.
  final double start;

  /// When it was sent: seconds since the epoch.
  final double wall;
  double? end;
  final Map<String, Object?> requestHeaders;
  final bool hasPostData;
  final String? postData;

  int? status;
  String? statusText;
  String? mimeType;
  Map<String, Object?>? responseHeaders;
  bool fromCache = false;

  /// Bytes over the network, once finished.
  int? size;
  bool finished = false;

  /// Why it failed, if it did.
  String? failure;

  void respond(Map<String, Object?> response) {
    status = (response['status'] as num?)?.toInt();
    statusText = response['statusText'] as String?;
    mimeType = response['mimeType'] as String?;
    responseHeaders = (response['headers'] as Map? ?? const {})
        .cast<String, Object?>();
    fromCache =
        response['fromDiskCache'] == true ||
        response['fromServiceWorker'] == true ||
        response['fromPrefetchCache'] == true;
  }

  /// How long it took, in milliseconds, once finished.
  int? get duration =>
      end == null ? null : ((end! - start) * 1000).round().clamp(0, 1 << 31);
}
