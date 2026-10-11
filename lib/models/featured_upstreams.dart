import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// An upstream Settings → Models shows a card of, free of charge, for
/// adding the one-click import (see docs/upstream-import.md): listed in
/// assets/upstreams/upstreams.json, by a pull request after its issue.
@immutable
class FeaturedUpstream {
  const FeaturedUpstream({
    required this.id,
    required this.name,
    required this.url,
    this.logo,
    this.description = const {},
    this.hosts = const [],
  });

  /// Null for an entry without an id, a name or an http(s) [url].
  static FeaturedUpstream? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    final url = Uri.tryParse('${json['url']}');
    if (id is! String || id.isEmpty || name is! String || name.isEmpty) {
      return null;
    }
    if (url == null || !(url.isScheme('https') || url.isScheme('http'))) {
      return null;
    }
    return FeaturedUpstream(
      id: id,
      name: name,
      url: url,
      logo: switch (json['logo']) {
        final String logo when logo.isNotEmpty => '$assetDirectory/$logo',
        _ => null,
      },
      description: {
        if (json['description'] case final Map map)
          for (final MapEntry(:key, :value) in map.entries)
            if (key is String && value is String) key: value,
      },
      hosts: [
        if (json['hosts'] case final List hosts)
          for (final host in hosts)
            if (host is String && host.isNotEmpty) host.toLowerCase(),
      ],
    );
  }

  final String id;
  final String name;

  /// Where its card goes: its site, the promotion's parameters in it if it
  /// has them.
  final Uri url;

  /// Its logo's asset (SVG or PNG); its name's first letter when null.
  final String? logo;

  /// A line about it, by language code (`en`, `zh`).
  final Map<String, String> description;

  /// The hosts its base URLs are at, by which an import is known to be
  /// its.
  final List<String> hosts;

  /// [description] in [languageCode], else in English, else any.
  String? describe(String languageCode) =>
      description[languageCode] ??
      description['en'] ??
      description.values.firstOrNull;

  static const assetDirectory = 'assets/upstreams';
  static const asset = '$assetDirectory/upstreams.json';

  /// Those listed in [json] (the asset's text), in its order.
  static List<FeaturedUpstream> parseList(String json) {
    final Object? data;
    try {
      data = jsonDecode(json);
    } on FormatException {
      return const [];
    }
    final list = data is Map ? data['upstreams'] : null;
    if (list is! List) return const [];
    return [for (final entry in list) ?fromJson(entry)];
  }

  static Future<List<FeaturedUpstream>>? _loaded;

  /// Those the app lists, read once.
  static Future<List<FeaturedUpstream>> load() => _loaded ??= rootBundle
      .loadString(asset)
      .then(parseList, onError: (Object _) => const <FeaturedUpstream>[]);

  /// The one of [upstreams] [host] is at; null for none.
  static FeaturedUpstream? at(String host, List<FeaturedUpstream> upstreams) {
    final lower = host.toLowerCase();
    return upstreams.where((u) => u.hosts.contains(lower)).firstOrNull;
  }
}
