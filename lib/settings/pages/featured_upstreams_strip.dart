import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../chat/widgets/hover_builder.dart';
import '../../chat/widgets/scroll_edge_fade.dart';
import '../../ide/ide_hover.dart';
import '../../l10n/l10n.dart';
import '../../models/featured_upstreams.dart';
import '../../theme/codicons.dart';
import '../../workspace/editor_launcher.dart' show openExternal;
import 'settings_widgets.dart';

/// Settings → Models' row of upstreams that added the one-click import
/// ([FeaturedUpstream]): a card of each, in an order of chance each time it
/// shows, scrolled sideways and faded out at an edge with more past it;
/// last, a card for a site to be among them. Under them, why they show.
class FeaturedUpstreamsStrip extends StatefulWidget {
  const FeaturedUpstreamsStrip({
    super.key,
    this.upstreams,
    this.random,
    this.open = _openUrl,
  });

  /// Those listed; the app's ([FeaturedUpstream.load]) when null.
  final Future<List<FeaturedUpstream>>? upstreams;

  /// What their order is drawn with.
  final Random? random;

  /// Opens a card's link.
  final void Function(Uri url) open;

  static void _openUrl(Uri url) => unawaited(openExternal('$url'));

  /// How tall a card is.
  static const cardHeight = 52.0;
  static const cardWidth = 196.0;

  /// The page for a site to be listed (site/upstreams.html).
  static Uri joinUrl(String languageCode) => Uri.https(
    'baocode.dev',
    languageCode == 'zh' ? '/zh/upstreams' : '/upstreams',
  );

  @override
  State<FeaturedUpstreamsStrip> createState() => _FeaturedUpstreamsStripState();
}

class _FeaturedUpstreamsStripState extends State<FeaturedUpstreamsStrip> {
  final ScrollController _scroll = ScrollController();
  List<FeaturedUpstream> _upstreams = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final listed = [...await (widget.upstreams ?? FeaturedUpstream.load())]
      ..shuffle(widget.random);
    if (mounted) setState(() => _upstreams = listed);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final language = Localizations.localeOf(context).languageCode;
    final cards = [
      for (final upstream in _upstreams)
        _Card(
          key: ValueKey(upstream.id),
          logo: _Logo(upstream),
          title: upstream.name,
          subtitle: upstream.describe(language) ?? upstream.url.host,
          hover: upstream.url.host,
          onTap: () => widget.open(upstream.url),
        ),
      _Card(
        key: const ValueKey('\u0000join'),
        logo: Icon(Codicons.add, size: 16, color: SettingsColors.iconTertiary),
        title: l10n.modelsFeaturedJoin,
        subtitle: l10n.modelsFeaturedJoinDescription,
        outlined: true,
        onTap: () => widget.open(FeaturedUpstreamsStrip.joinUrl(language)),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: FeaturedUpstreamsStrip.cardHeight,
          child: ScrollConfiguration(
            // Dragged with the mouse too: there may be no wheel sideways.
            behavior: ScrollConfiguration.of(context).copyWith(
              scrollbars: false,
              dragDevices: PointerDeviceKind.values.toSet(),
            ),
            child: ScrollEdgeFade(
              axis: Axis.horizontal,
              fadeLength: 40,
              child: ListView.separated(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                itemCount: cards.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, index) => cards[index],
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: IdeHover(
            message: l10n.modelsFeaturedWhyDetail,
            position: IdeHoverPosition.above,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Codicons.question,
                    size: 11,
                    color: SettingsColors.textQuaternary,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    l10n.modelsFeaturedWhy,
                    style: SettingsText.description.copyWith(
                      fontSize: 11,
                      color: SettingsColors.textQuaternary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A card of the row: [logo], [title] over [subtitle]; a click opens what
/// it is of.
class _Card extends StatelessWidget {
  const _Card({
    super.key,
    required this.logo,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.hover,
    this.outlined = false,
  });

  final Widget logo;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// Where it goes, in a hover.
  final String? hover;

  /// The card for a site to be listed: an outline, not a card's fill.
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final card = HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Semantics(
          button: true,
          link: true,
          label: '$title, $subtitle',
          excludeSemantics: true,
          child: Container(
            width: FeaturedUpstreamsStrip.cardWidth,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: outlined
                  ? (hovered ? SettingsColors.hover : null)
                  : hovered
                  ? Color.alphaBlend(SettingsColors.hover, SettingsColors.card)
                  : SettingsColors.card,
              borderRadius: BorderRadius.circular(10),
              border: outlined
                  ? Border.all(color: SettingsColors.stroke)
                  : null,
            ),
            child: Row(
              children: [
                SizedBox.square(dimension: 24, child: Center(child: logo)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SettingsText.label.copyWith(
                          fontSize: 12.5,
                          height: 1.3,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SettingsText.description.copyWith(
                          fontSize: 11.5,
                          height: 1.35,
                          color: SettingsColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final hover = this.hover;
    return hover == null ? card : IdeHover(message: hover, child: card);
  }
}

/// [upstream]'s logo, as it drew it; its name's first letter without one,
/// or while it cannot be read (not downloaded yet).
class _Logo extends StatelessWidget {
  const _Logo(this.upstream);

  final FeaturedUpstream upstream;

  @override
  Widget build(BuildContext context) {
    final letter = Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: SettingsColors.hover,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        upstream.name.characters.first.toUpperCase(),
        style: SettingsText.label.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: SettingsColors.textSecondary,
        ),
      ),
    );
    final logo = upstream.logo;
    if (logo == null) return letter;
    final file = File(logo);
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: logo.toLowerCase().endsWith('.svg')
          ? SvgPicture.file(
              file,
              width: 22,
              height: 22,
              errorBuilder: (_, _, _) => letter,
            )
          : Image.file(
              file,
              width: 22,
              height: 22,
              errorBuilder: (_, _, _) => letter,
            ),
    );
  }
}
