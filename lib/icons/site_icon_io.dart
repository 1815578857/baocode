import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'site_icon.dart';

/// See [fetchSiteIcon]: through the app's proxy, as every [HttpClient].
Future<T?> fetchSiteIcon<T>(
  Uri site,
  Future<T> Function(Uint8List bytes) take,
) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    // Some sites answer a browser only.
    ..userAgent =
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36';
  final tried = <Uri>{};
  try {
    for (final page in siteIconPages(site)) {
      final html = await _get(client, page, _maxPage);
      final icons = [
        if (html != null)
          ...siteIconLinks(
            utf8.decode(html.bytes, allowMalformed: true),
            html.url,
          ),
        html?.url.resolve('/favicon.ico') ?? page.resolve('/favicon.ico'),
      ];
      for (final icon in icons) {
        if (!tried.add(icon)) continue;
        final bytes = icon.isScheme('data')
            ? icon.data?.contentAsBytes()
            : (await _get(client, icon, _maxIcon))?.bytes;
        if (bytes == null || bytes.isEmpty) continue;
        try {
          return await take(bytes);
        } on Object {
          // Not a picture taken: the next.
        }
      }
    }
    return null;
  } finally {
    client.close(force: true);
  }
}

const _maxPage = 1024 * 1024;
const _maxIcon = 5 * 1024 * 1024;

/// What [url] answers, and where it ended up after redirects; null for a
/// failure, or more than [max] bytes.
Future<({Uint8List bytes, Uri url})?> _get(
  HttpClient client,
  Uri url,
  int max,
) async {
  try {
    final request = await client.getUrl(url);
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().catchError((_) {});
      return null;
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      builder.add(chunk);
      if (builder.length > max) return null;
    }
    var at = url;
    for (final redirect in response.redirects) {
      at = at.resolveUri(redirect.location);
    }
    return (bytes: builder.takeBytes(), url: at);
  } on Object {
    return null;
  }
}
