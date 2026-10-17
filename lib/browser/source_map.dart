import 'dart:convert';

/// A source map (version 3): where each piece of a script (bundled,
/// minified) came from in the sources it was built of, and back. Index maps
/// (sections) too.
class SourceMap {
  SourceMap._(this.sources, this._contents, this._lines);

  /// Reads [json], the map of a script at [url] (its sources' URLs are
  /// resolved against it); null if it is not a source map.
  static SourceMap? parse(String json, {String? url}) {
    try {
      final map = jsonDecode(json);
      if (map is! Map) return null;
      final sources = <String>[];
      final contents = <String?>[];
      final lines = <List<_Segment>>[];
      _read(map, url, 0, 0, sources, contents, lines);
      return SourceMap._(sources, contents, lines);
    } on Object {
      return null;
    }
  }

  static void _read(
    Map map,
    String? url,
    int lineOffset,
    int columnOffset,
    List<String> sources,
    List<String?> contents,
    List<List<_Segment>> lines,
  ) {
    if (map['sections'] case final List sections) {
      for (final section in sections.cast<Map>()) {
        final offset = section['offset'] as Map? ?? const {};
        if (section['map'] case final Map inner) {
          _read(
            inner,
            url,
            lineOffset + ((offset['line'] as num?)?.toInt() ?? 0),
            (offset['column'] as num?)?.toInt() ?? 0,
            sources,
            contents,
            lines,
          );
        }
      }
      return;
    }
    final root = map['sourceRoot'] as String? ?? '';
    final first = sources.length;
    final own = (map['sources'] as List? ?? const []);
    final ownContents = map['sourcesContent'] as List?;
    for (final (i, source) in own.indexed) {
      sources.add(_resolve(url, root, '${source ?? ''}'));
      contents.add(
        ownContents != null && i < ownContents.length
            ? ownContents[i] as String?
            : null,
      );
    }
    final names = (map['names'] as List? ?? const []).cast<Object?>();
    final mappings = map['mappings'] as String? ?? '';
    var line = lineOffset;
    var column = 0;
    var source = 0;
    var sourceLine = 0;
    var sourceColumn = 0;
    var name = 0;
    var first0 = true;
    for (final text in mappings.split(';')) {
      while (lines.length <= line) {
        lines.add([]);
      }
      column = 0;
      for (final piece in text.split(',')) {
        if (piece.isEmpty) continue;
        final values = _vlq(piece);
        column += values[0];
        final at = column + (first0 ? columnOffset : 0);
        if (values.length >= 4) {
          source += values[1];
          sourceLine += values[2];
          sourceColumn += values[3];
          String? named;
          if (values.length >= 5) {
            name += values[4];
            if (name >= 0 && name < names.length) named = '${names[name]}';
          }
          lines[line].add(
            _Segment(at, first + source, sourceLine, sourceColumn, named),
          );
        } else {
          lines[line].add(_Segment(at, -1, 0, 0, null));
        }
      }
      line++;
      first0 = false;
    }
    for (final segments in lines) {
      segments.sort((a, b) => a.column.compareTo(b.column));
    }
  }

  static String _resolve(String? url, String root, String source) {
    var path = source;
    if (root.isNotEmpty) {
      path = root.endsWith('/') ? '$root$source' : '$root/$source';
    }
    if (url == null || url.startsWith('data:')) return path;
    try {
      return Uri.parse(url).resolve(path).toString();
    } on FormatException {
      return path;
    }
  }

  static const _base64 =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  static List<int> _vlq(String piece) {
    final out = <int>[];
    var value = 0;
    var shift = 0;
    for (final char in piece.codeUnits) {
      final digit = _base64.indexOf(String.fromCharCode(char));
      if (digit < 0) break;
      value += (digit & 31) << shift;
      if (digit & 32 != 0) {
        shift += 5;
        continue;
      }
      out.add(value & 1 == 1 ? -(value >> 1) : value >> 1);
      value = 0;
      shift = 0;
    }
    return out;
  }

  /// The sources' URLs, resolved.
  final List<String> sources;
  final List<String?> _contents;

  /// Each generated line's segments, by column.
  final List<List<_Segment>> _lines;

  Map<int, List<_Segment>>? _bySource;

  /// [source]'s text, if the map has it.
  String? content(int source) =>
      source >= 0 && source < _contents.length ? _contents[source] : null;

  /// Where the script's [line] and [column] (from 0) came from; null where
  /// nothing maps.
  SourcePosition? original(int line, int column) {
    if (line < 0 || line >= _lines.length) return null;
    final segments = _lines[line];
    var low = 0;
    var high = segments.length - 1;
    _Segment? found;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (segments[mid].column <= column) {
        found = segments[mid];
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    // Before the line's first: its first, as DevTools does.
    found ??= segments.isEmpty ? null : segments.first;
    if (found == null || found.source < 0) return null;
    return SourcePosition(
      sources[found.source],
      found.source,
      found.sourceLine,
      found.sourceColumn,
      found.name,
    );
  }

  /// Where [source]'s [line] (from 0) is in the script: its first piece
  /// there, else on the nearest line after (up to a few); null if none.
  ({int line, int column})? generated(int source, int line) {
    final index = _bySource ??= _index();
    final segments = index[source];
    if (segments == null) return null;
    ({int line, int column})? best;
    var bestLine = 1 << 30;
    for (final s in segments) {
      if (s.sourceLine < line || s.sourceLine > line + 5) continue;
      final at = (line: s.generatedLine, column: s.column);
      if (s.sourceLine < bestLine ||
          (s.sourceLine == bestLine &&
              (at.line < best!.line ||
                  (at.line == best.line && at.column < best.column)))) {
        best = at;
        bestLine = s.sourceLine;
      }
    }
    return best;
  }

  Map<int, List<_Segment>> _index() {
    final index = <int, List<_Segment>>{};
    for (final (line, segments) in _lines.indexed) {
      for (final s in segments) {
        if (s.source < 0) continue;
        (index[s.source] ??= []).add(s..generatedLine = line);
      }
    }
    return index;
  }

  /// The source whose URL ends with [path] (or has it), best first: an
  /// exact end over a part.
  int? find(String path) {
    if (path.isEmpty) return null;
    int? part;
    for (final (i, source) in sources.indexed) {
      if (source == path || source.endsWith('/$path')) return i;
      if (part == null && source.contains(path)) part = i;
    }
    return part;
  }
}

class _Segment {
  _Segment(
    this.column,
    this.source,
    this.sourceLine,
    this.sourceColumn,
    this.name,
  );

  final int column;
  final int source;
  final int sourceLine;
  final int sourceColumn;
  final String? name;

  /// Set as the map is indexed by source.
  int generatedLine = 0;
}

/// A place in a source a map names: [line] and [column] from 0.
class SourcePosition {
  const SourcePosition(
    this.url,
    this.source,
    this.line,
    this.column,
    this.name,
  );

  final String url;
  final int source;
  final int line;
  final int column;

  /// The name there (the function's, a variable's), if the map says.
  final String? name;

  /// As a person reads it: its path short, lines and columns from 1.
  @override
  String toString() => '${shortSource(url)}:${line + 1}:${column + 1}';
}

/// A source's URL as it is read: `webpack://app/./src/App.tsx` as
/// `src/App.tsx`.
String shortSource(String url) {
  var path = url;
  final scheme = RegExp(r'^[a-z][a-z0-9+.-]*://[^/]*/').firstMatch(path);
  if (scheme != null) path = path.substring(scheme.end);
  path = path.replaceFirst(RegExp(r'^(\./)+'), '');
  return path.isEmpty ? url : path;
}
