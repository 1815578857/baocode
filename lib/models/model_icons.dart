import 'package:flutter/material.dart';

import '../icons/brand_logos.dart';
import '../icons/icon_library.dart';
import '../icons/project_icon.dart';
import '../icons/project_icon_view.dart';
import 'model_brand.dart';
import 'model_provider.dart';
import 'model_providers.dart';

/// Claude Code's own models' heading's logo.
const builtinProviderLogo = 'claudecode';

/// The icon [provider] shows: the one picked for it, else its maker's
/// logo; null when it has neither.
ProjectIcon? providerIconOf(ModelProvider provider) =>
    provider.icon ??
    switch (ModelBrand.ofProvider(provider)) {
      final brand? => BrandIcon(brand),
      null => null,
    };

/// Provider [id]'s icon (of [ModelProviders.current], as it is now) in a
/// square of [size]: a glyph or a logo as large as a glyph of it, a picture
/// a little larger; [Icons.hub_outlined] when it has none.
class ProviderIcon extends StatelessWidget {
  const ProviderIcon(this.id, {super.key, required this.size, this.color});

  /// Claude Code's own ([builtinProviderId]), or an upstream's.
  final String id;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (id == builtinProviderId) {
      return BrandLogo(builtinProviderLogo, size: size, color: color);
    }
    final providers = ModelProviders.current;
    return ListenableBuilder(
      listenable: providers,
      builder: (context, _) => ProviderIconView(
        icon: switch (providers.provider(id)) {
          final provider? => providerIconOf(provider),
          null => null,
        },
        size: size,
        color: color,
      ),
    );
  }
}

/// [icon] as an upstream shows it, in a square of [size]: see
/// [ProviderIcon].
class ProviderIconView extends StatelessWidget {
  const ProviderIconView({
    super.key,
    required this.icon,
    required this.size,
    this.color,
  });

  final ProjectIcon? icon;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => switch (icon) {
    null => Icon(Icons.hub_outlined, size: size, color: color),
    BrandIcon(:final name) => BrandLogo(name, size: size, color: color),
    final icon => ListenableBuilder(
      listenable: IconLibrary.current,
      builder: (context, _) => SizedBox.square(
        dimension: size,
        // Takes the room of a glyph of [size]; a picture spills over it a
        // little, as large as the glyph looks.
        child: OverflowBox(
          maxWidth: size + 3,
          maxHeight: size + 3,
          child: ProjectIconView(
            icon: icon,
            library: IconLibrary.current,
            size: size + 3,
            color: color,
            fallback: Icons.hub_outlined,
          ),
        ),
      ),
    ),
  };
}

/// Model [model]'s icon: its maker's logo, as its name says; else its
/// upstream's ([provider], [builtinProviderId] for Claude Code's own).
class ModelIcon extends StatelessWidget {
  const ModelIcon({
    super.key,
    required this.provider,
    required this.model,
    required this.size,
    this.color,
  });

  final String provider;
  final String model;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => switch (provider == builtinProviderId
      ? 'claude'
      : ModelBrand.ofModel(model)) {
    final brand? => BrandLogo(brand, size: size, color: color),
    null => ProviderIcon(provider, size: size, color: color),
  };
}
