import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';

Builder summaryBuilder(BuilderOptions options) => _SummaryBuilder();

/// A resolver-only builder: it observes the input library and its
/// imports exclusively through the element model, which is the
/// observation contract the API cutoff (ADR 0056) relies on.
class _SummaryBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.summary.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final library = await buildStep.resolver.libraryFor(buildStep.inputId);
    final seen = <String>{};
    final lines = <String>[];
    void visit(LibraryElement lib) {
      if (!seen.add(lib.uri.toString())) return;
      for (final cls in lib.classes) {
        final methods = cls.methods.map((method) => method.name).join(',');
        lines.add('${lib.uri}: ${cls.name} [$methods]');
      }
      for (final imported in lib.firstFragment.importedLibraries) {
        visit(imported);
      }
    }

    visit(library);
    lines.sort();
    await buildStep.writeAsString(
      buildStep.inputId.changeExtension('.summary.txt'),
      lines.join('\n'),
    );
  }
}

Builder probeBuilder(BuilderOptions options) => _ProbeBuilder();

/// A resolver-only builder that resolves a NON-primary library by
/// asset id. The resolver's internal readability probe preloads that
/// library through the shared content path; the preload must be
/// attributed to the resolver channel, or the library lands in the
/// action's direct reads and the cutoff can never engage for this
/// builder shape.
class _ProbeBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.probe.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final api = AssetId(buildStep.inputId.package, 'lib/api.dart');
    final library = await buildStep.resolver.libraryFor(api);
    final lines = <String>[];
    for (final cls in library.classes) {
      final methods = cls.methods.map((method) => method.name).join(',');
      lines.add('${cls.name} [$methods]');
    }
    lines.sort();
    await buildStep.writeAsString(
      buildStep.inputId.changeExtension('.probe.txt'),
      lines.join('\n'),
    );
  }
}

Builder astBuilder(BuilderOptions options) => _AstBuilder();

/// An opted-in builder that observes a dependency through its AST
/// (compilationUnitFor) instead of the element model. AST access
/// observes source text, including bodies the API fingerprint does
/// not cover, so the cutoff's safety net must downgrade this
/// builder: the dependency stays content-keyed and a body-only edit
/// reruns the action even though the builder is opted in. The
/// output embeds the method bodies themselves, so a stale waiver
/// would be visible as a mismatch against stock.
class _AstBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.ast.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final api = AssetId(buildStep.inputId.package, 'lib/api.dart');
    final unit = await buildStep.resolver.compilationUnitFor(api);
    final lines = <String>[];
    for (final declaration in unit.declarations) {
      if (declaration is! ClassDeclaration) continue;
      final className = declaration.namePart.typeName.lexeme;
      for (final member in declaration.body.members) {
        if (member is MethodDeclaration) {
          lines.add(
            '$className.${member.name.lexeme}:${member.body.toSource()}',
          );
        } else if (member is ConstructorDeclaration) {
          lines.add('$className.ctor:${member.parameters.toSource()}');
        } else if (member is FieldDeclaration) {
          for (final field in member.fields.variables) {
            lines.add('$className.${field.name.lexeme}');
          }
        }
      }
    }
    lines.sort();
    await buildStep.writeAsString(
      buildStep.inputId.changeExtension('.ast.txt'),
      lines.join('\n'),
    );
  }
}

Builder combineBuilder(BuilderOptions options) => _CombineBuilder();

/// A combining builder downstream of the summary builder. Its input
/// is a generated asset, which stays content-keyed: when the summary
/// action is waived by the cutoff its previous output stays in
/// place, so this builder sees no change and also holds; when the
/// summary content changes, this builder reruns.
class _CombineBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.summary.txt': ['.combined.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final summary = await buildStep.readAsString(buildStep.inputId);
    // changeExtension would only replace the trailing '.txt'; the
    // declared output replaces the whole '.summary.txt' suffix.
    final inputPath = buildStep.inputId.path;
    final outputId = AssetId(
      buildStep.inputId.package,
      '${inputPath.substring(0, inputPath.length - '.summary.txt'.length)}'
      '.combined.txt',
    );
    await buildStep.writeAsString(outputId, 'combined summary\n$summary');
  }
}

Builder echoBuilder(BuilderOptions options) => _EchoBuilder();

/// An opted-in builder whose output depends on a direct content read
/// of a library it also resolves. The read must stay content-keyed
/// even though the same action also observes the library through
/// the resolver channel: builder steps load content through the
/// filesystem's shared contentOf, and misattributing that path to
/// the resolver channel (or subtracting it because the resolver
/// observed the same asset) would let the cutoff waive a real
/// content dependency.
class _EchoBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.echo.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final api = AssetId(buildStep.inputId.package, 'lib/api.dart');
    final library = await buildStep.resolver.libraryFor(api);
    final text = await buildStep.readAsString(api);
    await buildStep.writeAsString(
      buildStep.inputId.changeExtension('.echo.txt'),
      '${library.name}\n$text',
    );
  }
}
