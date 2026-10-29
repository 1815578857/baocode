import 'package:bao_link/bao_link.dart'
    show BotAbility, BotProactive, isAvatarImage;
import 'package:path/path.dart' as p;

export 'package:bao_link/bao_link.dart'
    show BotAbility, BotProactive, isAvatarImage;

/// A bot as the user made it: who it is ([identity], [gender], [style],
/// their words), what it
/// may do ([abilities]). Its conversation runs in a folder of its own
/// ([folder]), where what it remembers is kept too (see bot_folders.dart).
/// [proactive] is as older phones set it: unused, it judges for itself.
class Bot {
  const Bot({
    required this.id,
    required this.name,
    required this.folder,
    this.avatar,
    this.gender = '',
    this.signature = '',
    this.identity = '',
    this.style = '',
    this.abilities = const {},
    this.proactive = const BotProactive(),
    this.model,
    this.assistant = false,
    this.created,
  });

  /// [json] as kept, its folder in [root].
  static Bot? fromJson(Object? json, {required String root}) => switch (json) {
    {'id': final String id, 'name': final String name} => Bot(
      id: id,
      name: name,
      folder: p.join(root, id),
      avatar: json['avatar'] as String?,
      gender: json['gender'] as String? ?? '',
      signature: json['signature'] as String? ?? '',
      identity: json['identity'] as String? ?? '',
      style: json['style'] as String? ?? '',
      abilities: {
        for (final name in (json['abilities'] as List?) ?? const [])
          ?BotAbility.values.asNameMap()[name],
        // Those come since it was kept: on for the assistant, as all of
        // its are; off for the user's own, as a new bot's are.
        if (json['assistant'] == true)
          for (final ability in BotAbility.values)
            if (!switch (json['known']) {
              final List known => known.contains(ability.name),
              _ => _firstAbilities.contains(ability.name),
            })
              ability,
      },
      proactive: switch (json['proactive']) {
        final Map<String, Object?> proactive => BotProactive.fromJson(
          proactive,
        ),
        _ => const BotProactive(),
      },
      model: json['model'] as String?,
      assistant: json['assistant'] == true,
      created: switch (json['created']) {
        final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
        _ => _createdIn(id),
      },
    ),
    _ => null,
  };

  /// When a bot named [id] was made, as its id says (`b` and the time,
  /// see Bots); null for one whose does not.
  static DateTime? _createdIn(String id) {
    final match = RegExp(r'^b([0-9a-z]+)(?:-\d+)?$').firstMatch(id);
    final micros = match == null ? null : int.tryParse(match[1]!, radix: 36);
    return micros == null ? null : DateTime.fromMicrosecondsSinceEpoch(micros);
  }

  final String id;
  final String name;

  /// Where its conversation runs, and its memory is kept.
  final String folder;

  /// An emoji, or its picture: the name of its file in [folder]
  /// ([isAvatarImage]); none for its name's first letter.
  final String? avatar;

  /// Its picture's file, if it has one.
  String? get avatarFile =>
      isAvatarImage(avatar) ? p.join(folder, avatar) : null;

  /// The abilities there were before the app kept which it knew of.
  static const _firstAbilities = {
    'viewChats',
    'manageTasks',
    'sendToChats',
    'newChat',
    'readFiles',
    'browser',
    'proactive',
  };

  /// As the user put it: a word, or none.
  final String gender;

  /// A line under its name, as the user wrote it.
  final String signature;

  /// Who it is, as the user wrote it.
  final String identity;

  /// How it talks, as the user wrote it.
  final String style;
  final Set<BotAbility> abilities;
  final BotProactive proactive;

  /// The model it runs on; none for the app's.
  final String? model;

  /// The one the app starts with, which is not deleted.
  final bool assistant;

  /// When the user made it, where known.
  final DateTime? created;

  bool can(BotAbility ability) => abilities.contains(ability);

  Bot copyWith({
    String? name,
    String? avatar,
    bool clearAvatar = false,
    String? gender,
    String? signature,
    String? identity,
    String? style,
    Set<BotAbility>? abilities,
    BotProactive? proactive,
    String? model,
  }) => Bot(
    id: id,
    name: name ?? this.name,
    folder: folder,
    avatar: clearAvatar ? null : avatar ?? this.avatar,
    gender: gender ?? this.gender,
    signature: signature ?? this.signature,
    identity: identity ?? this.identity,
    style: style ?? this.style,
    abilities: abilities ?? this.abilities,
    proactive: proactive ?? this.proactive,
    model: model ?? this.model,
    assistant: assistant,
    created: created,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'avatar': ?avatar,
    if (gender.isNotEmpty) 'gender': gender,
    if (signature.isNotEmpty) 'signature': signature,
    'identity': identity,
    if (style.isNotEmpty) 'style': style,
    'abilities': [
      for (final ability in BotAbility.values)
        if (abilities.contains(ability)) ability.name,
    ],
    // Which there were, to tell those that come later.
    'known': [for (final ability in BotAbility.values) ability.name],
    'proactive': proactive.toJson(),
    'model': ?model,
    if (assistant) 'assistant': true,
    'created': ?created?.millisecondsSinceEpoch,
  };
}
