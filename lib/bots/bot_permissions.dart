import 'bot.dart';

/// What a bot's agent has of Claude Code's own tools. It runs in full
/// access, nothing asked: what it would do, it does.
abstract final class BotPermissions {
  /// The web's, every bot's: searching it, reading a page.
  static const webTools = ['WebSearch', 'WebFetch'];

  /// Working on the computer: reading and writing files (its own, the
  /// projects'), running commands.
  static const handTools = ['Read', 'Write', 'Edit', 'Bash'];

  /// Claude Code's tools [bot] has; the tool search, for the browser's
  /// (deferred), if it may use it.
  static List<String> tools(Bot bot) => [
    ...webTools,
    if (bot.reaches(BotLevel.computer)) ...handTools,
    if (bot.can(BotAbility.browser)) 'ToolSearch',
  ];

  /// The [projects] it works in as Claude Code's working directories, if
  /// it may work on them.
  static List<String> reaches(Bot bot, {required List<String> projects}) =>
      bot.reaches(BotLevel.computer) ? projects : const [];
}
