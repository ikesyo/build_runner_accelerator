import 'package:build/build.dart';
import 'package:build_runner_accelerator/src/worker.dart';
import 'package:glob/glob.dart';

class _GlobFindingBuilder implements Builder {
  _GlobFindingBuilder(this.options);
  final BuilderOptions options;

  @override
  final buildExtensions = const {
    '.dart': ['.out'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final pattern =
        options.config['pattern'] as String? ??
        buildStep.inputId.changeExtension('.*.part').path;
    final found = await buildStep.findAssets(Glob(pattern)).toList();
    await buildStep.writeAsString(
      buildStep.inputId.changeExtension('.out'),
      found.map((id) => id.toString()).join('\n'),
    );
  }
}

Future<void> main() =>
    runWorker(catalog: {'glob_cache_test:find': _GlobFindingBuilder.new});
