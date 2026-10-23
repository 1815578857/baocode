import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/ide/markdown/markdown_front_matter.dart';

void main() {
  test('a skill\'s front matter reads as its keys and values', () {
    final properties = parseFrontMatterProperties(
      'name: baocode-stash\n'
      'description: "The user\'s Stash: ideas, \\"bugs\\""\n'
      'allowed-tools:\n'
      '  - "Read(//Users/me/Stash/**)"\n'
      '  - Edit\n'
      'tags: [a, \'it\'\'s\']\n'
      '# a comment\n'
      'notes: >\n'
      '  two\n'
      '  lines\n'
      'empty:\n',
    );
    expect(
      [
        for (final property in properties!)
          '${property.key} = ${property.text ?? property.items}',
      ],
      [
        'name = baocode-stash',
        'description = The user\'s Stash: ideas, "bugs"',
        'allowed-tools = [Read(//Users/me/Stash/**), Edit]',
        "tags = [a, it's]",
        'notes = two lines',
        'empty = ',
      ],
    );
  });

  test('what is not keys and values shows as YAML', () {
    expect(parseFrontMatterProperties('  indented: first'), isNull);
    expect(parseFrontMatterProperties('just text'), isNull);
    expect(parseFrontMatterProperties(''), isNull);
  });
}
