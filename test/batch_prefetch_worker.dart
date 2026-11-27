import 'package:build/build.dart';
import 'package:build_runner_accelerator/src/worker.dart';

class _ReadingBuilder implements Builder {
  _ReadingBuilder(this.options);
  final BuilderOptions options;

  @override
  final buildExtensions = const {
    '.txt': ['.out'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final extra = options.config['extra_read'] as String?;
    final target = extra == null ? buildStep.inputId : AssetId.parse(extra);
    final readable = await buildStep.canRead(target);
    final content = readable
        ? await buildStep.readAsString(target)
        : '<missing>';
    await buildStep.writeAsString(
      buildStep.inputId.changeExtension('.out'),
      content,
    );
  }
}

class _NoopPostBuilder implements PostProcessBuilder {
  @override
  final inputExtensions = const ['.txt'];

  @override
  Future<void> build(PostProcessBuildStep buildStep) async {
    buildStep.deletePrimaryInput();
  }
}

Future<void> main() => runWorker(
  catalog: {'prefetch_test:read': _ReadingBuilder.new},
  postProcessCatalog: {'prefetch_test:post': (_) => _NoopPostBuilder()},
);
