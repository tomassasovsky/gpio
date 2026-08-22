import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// pub.dev scores the pubspec, and one of its checks is a hard range on the
/// description. 0.1.0 shipped at ~258 characters and scored 0/10 on "Provide a
/// valid pubspec.yaml" for it. A published pubspec is immutable, so the only
/// remedy was a new version — which makes this worth pinning rather than
/// rediscovering after the next release.
void main() {
  final pubspec = loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;

  group('pubspec description', () {
    // https://pub.dev/help/scoring: "between 60 and 180 characters".
    const minLength = 60;
    const maxLength = 180;

    test('is within the length pub.dev scores', () {
      final description = pubspec['description'] as String;
      expect(
        description.length,
        inInclusiveRange(minLength, maxLength),
        reason: 'pub.dev gives 0/10 for "Provide a valid pubspec.yaml" outside '
            '$minLength-$maxLength characters. Got ${description.length}. '
            'The long-form pitch belongs in the README.',
      );
    });

    test('is a single line once folded', () {
      // The `>-` block folds to one line. A stray blank line in it would
      // produce a newline, which reads badly wherever pub.dev renders it.
      expect(pubspec['description'], isNot(contains('\n')));
    });
  });

  test('version is not a pre-release placeholder', () {
    expect(pubspec['version'], isNot(anyOf('0.0.0', '1.0.0')));
  });
}
