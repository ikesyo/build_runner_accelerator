import 'dart:io';

import 'package:build_runner_accelerator/src/reset_directives.dart';

/// AOT compile, then supply a directory of measured Dart/part outputs.
/// Decode/setup and correctness checks are untimed. Each lane gets fresh Strings.
void main(List<String> arguments) {
  List<String> readContents() => Directory(arguments.single)
      .listSync(recursive: true)
      .whereType<File>()
      .where(
        (file) => file.path.endsWith('.dart') || file.path.endsWith('.part'),
      )
      .map((file) => file.readAsStringSync())
      .toList();
  print('repeat,case,lane,elapsed_us,files,code_units');
  for (var repeat = 0; repeat < 7; repeat++) {
    for (final condition in ['missing-old', 'same-old', 'changed-old']) {
      for (final lane
          in repeat.isEven
              ? ['baseline', 'candidate']
              : ['candidate', 'baseline']) {
        final contents = readContents();
        final old = condition == 'changed-old'
            ? contents.map((text) => '$text\nclass OldVersion {}').toList()
            : readContents();
        final results = <(Set<String>, Set<String>?)>[];
        final watch = Stopwatch()..start();
        for (var i = 0; i < contents.length; i++) {
          if (lane == 'baseline') {
            Set<String> extract(String text) => ResetDirectiveContent.pattern
                .allMatches(text)
                .map((match) => match.group(0)!.trim())
                .toSet();
            results.add((
              extract(contents[i]),
              condition == 'missing-old' ? null : extract(old[i]),
            ));
          } else {
            final current = ResetDirectiveContent(contents[i]);
            final previous = condition == 'missing-old'
                ? null
                : current.reuse(old[i]) ?? ResetDirectiveContent(old[i]);
            results.add((current.directives, previous?.directives));
          }
        }
        watch.stop();
        for (var i = 0; i < contents.length; i++) {
          final reference = ResetDirectiveContent(contents[i]).directives;
          if (results[i].$1.length != reference.length ||
              !results[i].$1.containsAll(reference)) {
            throw StateError('Different extraction');
          }
          if (condition != 'missing-old') {
            final reference = ResetDirectiveContent(old[i]).directives;
            if (results[i].$2!.length != reference.length ||
                !results[i].$2!.containsAll(reference)) {
              throw StateError('Different old extraction');
            }
          }
        }
        print(
          '$repeat,$condition,$lane,${watch.elapsedMicroseconds},${contents.length},'
          '${contents.fold<int>(0, (sum, text) => sum + text.length)}',
        );
      }
    }
  }
}
