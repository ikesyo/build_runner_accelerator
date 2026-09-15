import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:build/build.dart';
import 'package:build_runner/src/build/builder_filesystem.dart'
    show BuilderFilesystem;
import 'package:build_runner/src/build/input_tracker.dart' show InputTracker;
import 'package:build_runner/src/build_plan/build_triggers.dart'
    show AnnotationBuildTrigger, BuildTrigger, ImportBuildTrigger;

/// The trigger representation emitted by the Dart manifest generator.
///
/// It is intentionally small: parsing and matching remain in build_runner's
/// BuildTrigger implementations, while Rust only transports this data.
class NormalizedBuildTrigger {
  const NormalizedBuildTrigger({required this.kind, required this.value});

  final String kind;
  final String value;

  static NormalizedBuildTrigger fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('build trigger must be an object');
    }
    final kind = raw['kind'];
    final value = raw['value'];
    if (kind is! String || value is! String) {
      throw const FormatException(
        'build trigger must contain string kind and value',
      );
    }
    return NormalizedBuildTrigger(kind: kind, value: value);
  }

  BuildTrigger toBuildTrigger() => switch (kind) {
    'import' => ImportBuildTrigger(value),
    'annotation' => AnnotationBuildTrigger(value),
    _ => throw FormatException('unsupported build trigger kind: $kind'),
  };
}

/// Evaluates a normal action's run-only trigger gate.
///
/// The returned [InputTracker] contains the primary input and every readable
/// part consulted by an annotation trigger. This makes the heuristic itself
/// part of invalidation, matching build_runner's trigger implementation.
Future<bool> evaluateBuildTriggers({
  required List<NormalizedBuildTrigger> triggers,
  required AssetId primaryInput,
  required int phase,
  required BuilderFilesystem filesystem,
  required InputTracker inputTracker,
}) async {
  if (triggers.isEmpty) return false;

  inputTracker.add(primaryInput);
  final primarySource = (await filesystem.contentOf(primaryInput))
      .stringValue();
  final primaryUnit = parseString(
    content: primarySource,
    throwIfDiagnostics: false,
  ).unit;
  List<CompilationUnit>? compilationUnits;

  for (final normalized in triggers) {
    final trigger = normalized.toBuildTrigger();
    if (trigger.checksParts) {
      compilationUnits ??= await _readCompilationUnits(
        primaryInput: primaryInput,
        primaryUnit: primaryUnit,
        phase: phase,
        filesystem: filesystem,
        inputTracker: inputTracker,
      );
      if (trigger.triggersOn(compilationUnits)) return true;
    } else if (trigger.triggersOn(<CompilationUnit>[primaryUnit])) {
      return true;
    }
  }
  return false;
}

Future<List<CompilationUnit>> _readCompilationUnits({
  required AssetId primaryInput,
  required CompilationUnit primaryUnit,
  required int phase,
  required BuilderFilesystem filesystem,
  required InputTracker inputTracker,
}) async {
  final result = <CompilationUnit>[primaryUnit];
  for (final directive in primaryUnit.directives) {
    if (directive is! PartDirective) continue;
    final partId = AssetId.resolve(
      Uri.parse(directive.uri.stringValue!),
      from: primaryInput,
    );
    if (!await filesystem.isReadable(partId, phase, catchInvalidInputs: true)) {
      continue;
    }
    inputTracker.add(partId);
    final partSource = (await filesystem.contentOf(partId)).stringValue();
    result.add(
      parseString(content: partSource, throwIfDiagnostics: false).unit,
    );
  }
  return result;
}
