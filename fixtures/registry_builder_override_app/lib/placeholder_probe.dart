import 'dart:convert';

import 'package:build/build.dart';
import 'package:glob/glob.dart';

/// Observes virtual-primary readability and the ordered later-phase asset view.
Builder placeholderProbe(BuilderOptions options) => _PlaceholderProbe();

class _PlaceholderProbe implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    r'$lib$': ['placeholder.probe.txt'],
    r'$test$': ['placeholder.probe.txt'],
    r'$web$': ['placeholder.probe.txt'],
  };

  @override
  Future<void> build(BuildStep step) async {
    final unreadable = <String>[];
    for (final path in [
      r'$package$',
      r'lib/$lib$',
      r'test/$test$',
      r'web/$web$',
    ]) {
      final id = AssetId(step.inputId.package, path);
      if (await step.canRead(id)) throw StateError('readable placeholder: $id');
      try {
        await step.readAsString(id);
        throw StateError('placeholder read succeeded: $id');
      } on AssetNotFoundException {
        unreadable.add(path);
      }
    }
    // Exercise a glob that can match all four IDs, separately from the ordered
    // lib snapshot used to observe the registry's generated-input view.
    final virtualPaths = unreadable.toSet();
    await for (final id in step.findAssets(Glob('**'))) {
      if (virtualPaths.contains(id.path)) {
        throw StateError('enumerable placeholder: $id');
      }
    }
    final assets = await step.findAssets(Glob('lib/**')).toList();
    final suffix = step.inputId.path.endsWith(r'$lib$')
        ? r'$lib$'
        : step.inputId.path.endsWith(r'$test$')
        ? r'$test$'
        : r'$web$';
    final output = AssetId(
      step.inputId.package,
      '${step.inputId.path.substring(0, step.inputId.path.length - suffix.length)}placeholder.probe.txt',
    );
    await step.writeAsString(
      output,
      '${jsonEncode({'primary': step.inputId.path, 'unreadable': unreadable, 'assets': assets.map((id) => id.path).toList()})}\n',
    );
  }
}
