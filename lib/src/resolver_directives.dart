import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/source/line_info.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/experiments.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/scanner/scanner.dart';
// ignore: implementation_imports
import 'package:analyzer/src/error/listener.dart';
// ignore: implementation_imports
import 'package:analyzer/src/generated/parser.dart';
// ignore: implementation_imports
import 'package:analyzer/src/string_source.dart';

/// Uses parseString's scanner/features, but avoids building declaration ASTs.
///
/// The worker supports Analyzer >=13.3.0 <15.0.0, whose directive parser has
/// this interface. On malformed directives or possible late import/exports,
/// retain parseString's full-unit recovery rather than losing dependency URIs.
List<Directive> parseResolverDirectives(String content) {
  final features = FeatureSet.latestLanguageVersion();
  final diagnostics = RecordingDiagnosticListener();
  final reporter = DiagnosticReporter(diagnostics, StringSource(content, ''));
  final scanner = Scanner(
    inputText: content,
    reportError: reporter.report,
  )..configureFeatures(featureSetForOverriding: features, featureSet: features);
  final token = scanner.tokenize();
  final parser = Parser(
    reporter,
    featureSet: scanner.featureSet,
    languageVersion: LibraryLanguageVersion(
      package: ExperimentStatus.currentVersion,
      override: scanner.overrideVersion,
    ),
    lineInfo: LineInfo(scanner.lineStarts),
  );
  final unit = parser.parseDirectives(token);
  var needsRecovery = diagnostics.diagnostics.isNotEmpty;
  // A full-unit parse can recover misplaced directives after declarations.
  // Strings/comments are separate tokens, so body text cannot hide a keyword.
  for (
    var remaining = unit.endToken;
    !needsRecovery && !remaining.isEof;
    remaining = remaining.next!
  ) {
    if (remaining.type == TokenType.BAD_INPUT ||
        remaining.keyword == Keyword.IMPORT ||
        remaining.keyword == Keyword.EXPORT) {
      needsRecovery = true;
    }
  }
  return (needsRecovery
          ? parseString(content: content, throwIfDiagnostics: false).unit
          : unit)
      .directives;
}
