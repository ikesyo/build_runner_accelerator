// Compiled only inside generated workers on the shared-part runner API.
const sharedPartsImports = r'''
// Imported by generated workers only when their catalog contains a shared-part
// builder. Older runner/build resolutions never compile this library.
import 'package:build_runner/src/build/br_outputs.dart';
import 'package:build_runner/src/build/build_step_impl.dart';
import 'package:build_runner/src/build/part_contribution.dart';
import 'package:build_runner/src/build/part_directives.dart';
import 'package:build_runner/src/build/shared_part_accumulator.dart';
import 'package:build_runner/src/build/input_tracker.dart';
import 'package:build_runner/src/build/builder_filesystem.dart';
import 'package:build/build.dart' show AssetId, Resolvers, ResourceManager;

''';

const sharedPartsImplementation = r'''
BuildStepImpl createSharedPartStep(
  AssetId input, Iterable<AssetId> outputs, InputTracker tracker,
  BuilderFilesystem filesystem, int phase, int partPhaseIndex,
  Resolvers resolvers, ResourceManager resources,
) => BuildStepImpl(
  inputId: input, expectedOutputs: outputs, inputTracker: tracker,
  buildFilesystem: filesystem, phase: phase, partPhaseIndex: partPhaseIndex,
  resolvers: resolvers, resourceManager: resources,
);

Future<Map<String, dynamic>> encodeSharedPart(BuildStepImpl step, String key) async {
  final id = step.inputId;
  final source = await step.readAsString(id);
  final uri = id.sharedPartUri;
  if (uri == null) throw StateError('Shared-part input is in the reserved namespace: $id');
  final accumulator = SharedPartAccumulator(id, step.languageVersion);
  if (step.wrotePartContribution) {
    accumulator.addContribution(step.phase, PartContribution.of(
      builderKey: key,
      imports: step.partImports,
      contribution: step.partContribution ?? '',
    ));
  }
  final content = accumulator.finalContent().stringValue();
  final importsMarker = '// === $key imports.\n';
  final sourceMarker = '// === $key contribution.\n';
  final importsStart = content.indexOf(importsMarker);
  final sourceStart = content.indexOf(sourceMarker);
  final first = [importsStart, sourceStart].where((offset) => offset >= 0).fold(content.length, (a, b) => a < b ? a : b);
  String? edit(bool add) {
    final edit = add ? PartDirectives.addEdit(source, uri) : PartDirectives.removeEdit(source, uri);
    return edit == null ? null : source.replaceRange(edit.offset, edit.offset + edit.length, edit.replacement);
  }
  return {
    'header': content.substring(0, first),
    'imports': importsStart < 0 ? '' : content.substring(importsStart, sourceStart < 0 ? content.length : sourceStart),
    'source': sourceStart < 0 ? '' : content.substring(sourceStart),
    'original': source,
    'with_part': edit(true),
    'without_part': edit(false),
  };
}
''';
