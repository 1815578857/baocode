import '../kernel/claude_code/claude_code_transport.dart' show ClaudeLaunch;
import 'bot.dart';

/// What a bot's agent has of Claude Code's own tools, what of it goes
/// without asking, and what is always asked: looking goes, as do edits in
/// the projects and the commands that only look or test; what removes,
/// publishes, installs, or changes memory and settings is asked, in its
/// chat. Not a guard against a bad actor: against a slip of the bot's.
abstract final class BotPermissions {
  /// The web's, every bot's: searching it, reading a page.
  static const webTools = ['WebSearch', 'WebFetch'];

  /// Reading the projects. (The Dart core has no Grep nor Glob: it greps
  /// and lists with commands then.)
  static const readTools = ['Read', 'Grep', 'Glob'];

  /// Working on them.
  static const handTools = ['Edit', 'Write', 'Bash'];

  /// The commands that only look or test, run unasked (each a prefix:
  /// `git status` and what follows it). Claude Code lets those it knows
  /// to only read run as well (`ls`, `cat`, `rg`…).
  static const lookCommands = [
    // Into a project first, as it mostly does: the rest is what is
    // judged.
    'cd',
    'ls',
    'cat',
    'head',
    'tail',
    'wc',
    'rg',
    'grep',
    'tree',
    'pwd',
    'which',
    'file',
    'du',
    'df',
    'stat',
    'date',
    'od',
    'sort',
    'uniq',
    'jq',
    'basename',
    'dirname',
    'realpath',
    'git status',
    'git diff',
    'git log',
    'git show',
    'git branch',
    'git blame',
    'git rev-parse',
    'git ls-files',
    'flutter test',
    'flutter analyze',
    'dart test',
    'dart analyze',
    'npm test',
    'npm run test',
    'pnpm test',
    'yarn test',
    'pytest',
    'python -m pytest',
    'python3 -m pytest',
    'go test',
    'go vet',
    'cargo test',
    'cargo check',
    'swift test',
  ];

  /// The commands always asked: they remove, publish, rewrite history,
  /// install, or reach past the project.
  static const askedCommands = [
    'rm',
    'rmdir',
    'sudo',
    'kill',
    'killall',
    'pkill',
    'chmod',
    'chown',
    'git push',
    'git reset',
    'git branch -d',
    'git branch -D',
    'git clean',
    'git rebase',
    'git restore',
    'git checkout --',
    'npm install',
    'npm i',
    'npm uninstall',
    'pnpm add',
    'pnpm install',
    'pnpm remove',
    'yarn add',
    'yarn install',
    'yarn remove',
    'pip install',
    'pip3 install',
    'pip uninstall',
    'uv add',
    'uv pip',
    'brew',
    'flutter pub add',
    'flutter pub upgrade',
    'flutter pub remove',
    'dart pub add',
    'dart pub upgrade',
    'dart pub remove',
    'cargo add',
    'cargo install',
    'go install',
    'go get',
    'curl',
    'wget',
  ];

  /// The files of the user's memory and settings, in each project, always
  /// asked before they are changed.
  static const askedInProjects = ['**/CLAUDE.md', '**/.env*', '**/.claude/**'];

  /// The same, of the user's home.
  static const askedAtHome = [
    '~/.claude/**',
    '~/.zshrc',
    '~/.zprofile',
    '~/.bashrc',
    '~/.bash_profile',
    '~/.profile',
    '~/.gitconfig',
    '~/.ssh/**',
  ];

  /// Claude Code's tools [bot] has; the browser's tool search, if it may
  /// use it.
  static List<String> tools(Bot bot) => [
    ...webTools,
    if (bot.can(BotAbility.readFiles) || bot.can(BotAbility.computer))
      ...readTools,
    if (bot.can(BotAbility.computer)) ...handTools,
    if (bot.can(BotAbility.browser)) 'ToolSearch',
  ];

  /// What [bot] does unasked: in its [folder] and the [projects] (local,
  /// absolute), reading, and if it may, editing and the commands that
  /// look or test.
  static List<String> allowed(
    Bot bot, {
    required String folder,
    required List<String> projects,
  }) {
    final reads = bot.can(BotAbility.readFiles) || bot.can(BotAbility.computer);
    final hands = bot.can(BotAbility.computer);
    return [
      ...webTools,
      for (final path in [folder, ...projects]) ...[
        if (reads) ClaudeLaunch.folderRule('Read', path),
        if (hands) ClaudeLaunch.folderRule('Edit', path),
      ],
      if (hands)
        for (final command in lookCommands) 'Bash($command:*)',
    ];
  }

  /// The [projects] it works in as Claude Code's working directories, if
  /// it reads or works in them.
  static List<String> reaches(Bot bot, {required List<String> projects}) =>
      bot.can(BotAbility.readFiles) || bot.can(BotAbility.computer)
      ? projects
      : const [];

  /// What [bot] always asks first, whatever allows it: the commands of
  /// [askedCommands]; changing the memory and settings of the user's, of
  /// the [projects], and its own memory in its [folder] (kept with its
  /// tool, not by hand).
  static List<String> asked(
    Bot bot, {
    required String folder,
    required List<String> projects,
  }) {
    if (!bot.can(BotAbility.computer)) return const [];
    String within(String path, String pattern) {
      final rule = ClaudeLaunch.folderRule('Edit', path);
      // `Edit(//x/**)` as `Edit(//x/<pattern>)`.
      return '${rule.substring(0, rule.length - 3)}$pattern)';
    }

    return [
      for (final command in askedCommands) 'Bash($command:*)',
      for (final path in projects)
        for (final pattern in askedInProjects) within(path, pattern),
      for (final pattern in askedAtHome) 'Edit($pattern)',
      within(folder, 'MEMORY.md'),
      within(folder, 'SELF.md'),
    ];
  }
}
