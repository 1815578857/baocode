// A markdown file's front matter, as its properties: a key and its value
// a row, a list's items as tags. Clicked, its YAML shows to be edited.

import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';
import '../../theme/workbench_theme.dart' show themeColors;

/// One of front matter's keys: its text, or its list's items.
typedef FrontMatterProperty = ({String key, String? text, List<String> items});

/// [yaml]'s keys at the top, in order, each with its value: a scalar's
/// text unquoted, a block's lines joined, a list's items (`- item`, or
/// `[a, b]`). Null where a line is not that (it shows as YAML instead).
List<FrontMatterProperty>? parseFrontMatterProperties(String yaml) {
  final properties = <FrontMatterProperty>[];
  String? key;
  String? text;
  var items = <String>[];
  final more = <String>[];

  void close() {
    final current = key;
    if (current == null) return;
    final rest = more.join(' ').trim();
    final joined = [?text, if (rest.isNotEmpty) rest].join(' ').trim();
    properties.add((
      key: current,
      text: items.isEmpty ? joined : null,
      items: items,
    ));
    key = null;
    text = null;
    items = [];
    more.clear();
  }

  final top = RegExp(r'^([^\s#:][^:]*):(?:\s+(.*))?$');
  for (final line in yaml.split(RegExp('\r\n|\r|\n'))) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    if (!line.startsWith(RegExp(r'\s')) && !line.startsWith('-')) {
      final match = top.firstMatch(line);
      if (match == null) return null;
      close();
      key = match[1]!.trim();
      final value = match[2]?.trim() ?? '';
      if (value.startsWith('[') && value.endsWith(']')) {
        items = [
          for (final item in value.substring(1, value.length - 1).split(','))
            if (_unquoted(item.trim()) case final item when item.isNotEmpty)
              item,
        ];
      } else if (value != '|' && value != '>' && value.isNotEmpty) {
        text = _unquoted(value);
      }
      continue;
    }
    if (key == null) return null;
    final trimmed = line.trim();
    if (trimmed.startsWith('- ') || trimmed == '-') {
      items.add(_unquoted(trimmed.substring(1).trim()));
    } else {
      more.add(trimmed);
    }
  }
  close();
  return properties.isEmpty ? null : properties;
}

/// [value] as YAML reads it quoted: `"…"` with its escapes, `'…'` with
/// `''` for a quote.
String _unquoted(String value) {
  if (value.length < 2) return value;
  final inner = value.substring(1, value.length - 1);
  if (value.startsWith('"') && value.endsWith('"')) {
    return inner.replaceAllMapped(
      RegExp(r'\\(.)'),
      (match) => switch (match[1]!) {
        'n' => '\n',
        't' => '\t',
        final other => other,
      },
    );
  }
  if (value.startsWith("'") && value.endsWith("'")) {
    return inner.replaceAll("''", "'");
  }
  return value;
}

/// Front matter's [properties] ([parseFrontMatterProperties]), a rule
/// under them. Taps go to the editor: its YAML shows where clicked.
class MarkdownFrontMatter extends StatelessWidget {
  const MarkdownFrontMatter({super.key, required this.properties});

  final List<FrontMatterProperty> properties;

  @override
  Widget build(BuildContext context) {
    final separator = themeColors['textSeparator.foreground'];
    return Container(
      padding: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: separator.withValues(alpha: separator.a * 0.33),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final property in properties) _Row(property)],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.property);

  final FrontMatterProperty property;

  @override
  Widget build(BuildContext context) {
    final value = TextStyle(
      color: AppColors.textPrimary,
      fontSize: 13,
      height: 1.5,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 128,
            child: Padding(
              padding: const EdgeInsets.only(top: 1, right: 12),
              child: Text(
                property.key,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.textFaint,
                  fontSize: 12.5,
                  height: 1.5,
                ),
              ),
            ),
          ),
          Expanded(
            child: property.items.isEmpty
                ? Text(
                    property.text?.isEmpty ?? true ? '—' : property.text!,
                    style: property.text?.isEmpty ?? true
                        ? value.copyWith(color: AppColors.textFaint)
                        : value,
                  )
                : Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final item in property.items) _Tag(item),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// A list's item.
class _Tag extends StatelessWidget {
  const _Tag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
    decoration: BoxDecoration(
      color: AppColors.inlineCodeBackground,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      text,
      style: AppFonts.uiCodeStyle(12).copyWith(
        color: AppColors.textMuted,
        height: 1.6,
      ),
    ),
  );
}
