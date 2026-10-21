import 'package:build/build.dart';
import 'package:build_runner_accelerator/src/worker.dart';

class LoggingBuilder implements Builder {
  LoggingBuilder(this.options);
  final BuilderOptions options;
  @override
  final buildExtensions = const {
    '.dart': ['.log.txt'],
  };
  @override
  Future<void> build(BuildStep step) async {
    await step.writeAsString(
      step.inputId.changeExtension('.log.txt'),
      'staged',
    );
    print('builder print');
    if (options.config['severe'] == true) {
      log.severe('normal severe without throw');
    } else {
      log.warning('normal warning');
    }
  }
}

class LoggingPostBuilder implements PostProcessBuilder {
  @override
  final inputExtensions = const ['.dart'];
  @override
  Future<void> build(PostProcessBuildStep step) async {
    await step.writeAsString(
      step.inputId.changeExtension('.log.txt'),
      'staged',
    );
    step.deletePrimaryInput();
    log.severe('post severe without throw');
  }
}

Future<void> main() => runWorker(
  catalog: {'logging:normal': LoggingBuilder.new},
  postProcessCatalog: {'logging:post': (_) => LoggingPostBuilder()},
);
