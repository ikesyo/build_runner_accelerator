import 'dart:convert';
import 'dart:io';
import 'package:build/build.dart';

Builder seedBuilder(BuilderOptions options) => SeedBuilder(options);
Builder summaryBuilder(BuilderOptions options) => SummaryBuilder(options);

// Histories and synchronization markers live outside the build workspace.
void event(BuildStep step, String stage, String event) {
  final directory = Platform.environment['SCHEDULER_HISTORY'];
  if (directory == null) return;
  final file = File(
    '$directory/${step.inputId.package}-$stage-${step.inputId.path.split('/').last}-$event.json',
  );
  file.writeAsStringSync(
    jsonEncode({
      'package': step.inputId.package,
      'input': step.inputId.path,
      'stage': stage,
      'event': event,
      'pid': pid,
      'time': DateTime.now().microsecondsSinceEpoch,
    }),
  );
}

Future<void> pause(BuildStep step, String stage) async {
  event(step, stage, 'start');
  final directory = Platform.environment['SCHEDULER_HISTORY'];
  final peer = switch (step.inputId.package) {
    'schedule_a' => 'schedule_b',
    'schedule_b' => 'schedule_a',
    _ => null,
  };
  if (Platform.environment['SCHEDULER_INPUT_RENDEZVOUS'] == '1' &&
      directory != null &&
      step.inputId.package == 'schedule_a' &&
      stage == 'seed') {
    final other = step.inputId.path == 'lib/input.seed' ? 'second' : 'input';
    final marker = File('$directory/schedule_a-seed-$other.seed-start.json');
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!marker.existsSync()) {
      if (DateTime.now().isAfter(deadline))
        throw StateError('same-package inputs did not overlap');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
  if (Platform.environment['SCHEDULER_RENDEZVOUS'] == '1' &&
      directory != null &&
      peer != null &&
      stage == 'seed' &&
      step.inputId.path == 'lib/input.seed') {
    final marker = File('$directory/$peer-seed-input.seed-start.json');
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!marker.existsSync()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('independent packages did not overlap');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
  await Future<void>.delayed(const Duration(milliseconds: 150));
}

class SeedBuilder implements Builder {
  SeedBuilder(this.options);
  final BuilderOptions options;
  @override
  Map<String, List<String>> get buildExtensions => {
    '.seed': ['.made.dart'],
  };
  @override
  Future<void> build(BuildStep step) async {
    await pause(step, 'seed');
    try {
      if (Platform.environment['SCHEDULER_CRASH'] == step.inputId.package) {
        exit(73);
      }
      final value = (await step.readAsString(step.inputId)).trim();
      if (value.contains('FAIL')) throw StateError('scheduler fixture failure');
      final tag = options.config['tag'] ?? 'default';
      final dependent = step.inputId.package == 'schedule_c';
      final imports = dependent
          ? "import 'package:schedule_a/input.made.dart' as dependency;\n"
          : '';
      final expression = dependent ? ' + dependency.generated' : '';
      await step.writeAsString(
        step.allowedOutputs.single,
        "$imports const generated = '$value:$tag:${options.isRoot}'$expression;\n",
      );
    } finally {
      event(step, 'seed', 'end');
    }
  }
}

class SummaryBuilder implements Builder {
  SummaryBuilder(this.options);
  final BuilderOptions options;
  @override
  Map<String, List<String>> get buildExtensions => {
    '.made.dart': ['.summary'],
  };
  @override
  Future<void> build(BuildStep step) async {
    await pause(step, 'summary');
    try {
      // Analyze the generated library, exercising resolver hydration on new
      // and reused package contexts. Also read a dependency's generated asset.
      final library = await step.resolver.libraryFor(step.inputId);
      final resolved = library.topLevelVariables.single
          .computeConstantValue()
          ?.toStringValue();
      final own = await step.readAsString(step.inputId);
      final dependency = options.config['dependency'] as String?;
      final extra = dependency == null
          ? ''
          : await step.readAsString(AssetId(dependency, 'lib/input.made.dart'));
      await step.writeAsString(
        step.allowedOutputs.single,
        '${library.topLevelVariables.single.name}:$resolved\n$own$extra'
        '${options.config['tag']}:${options.isRoot}\n',
      );
    } finally {
      event(step, 'summary', 'end');
    }
  }
}
