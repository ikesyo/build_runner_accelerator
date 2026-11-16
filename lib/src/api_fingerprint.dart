import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/unlinked_api_signature.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/ast/ast.dart' as impl;
import 'package:path/path.dart' as p;

import 'blake3.dart';
import 'cache_directory.dart';
import 'indexed_blob_store.dart';

/// API fingerprint of one compilation unit (ADR 0056).
///
/// The fingerprint identifies everything a dependent action can observe
/// about the unit through the resolver's element model, so that a later
/// build can skip re-running those actions when a content edit leaves
/// the fingerprint unchanged. It combines three components:
///
/// 1. The analyzer's unlinked API signature
///    (`computeUnlinkedApiSignature`): declarations, metadata, constant
///    initializers, parameter defaults and inference-relevant syntax,
///    with executable bodies reduced to their modifiers.
/// 2. A digest of the unit's doc comments, each bound to the node that
///    owns it. Generators can copy doc comments into their output, but
///    the analyzer signature deliberately excludes them, and a flat
///    list would miss a comment moved from one declaration to another.
/// 3. A digest of the bodies of executables whose return type is
///    omitted. Their inferred types are observable through the element
///    model, but the analyzer signature does not cover body edits that
///    change the inferred type; the analyzer itself tolerates this
///    because its unlinked entries are content-keyed and the owning
///    library cycle re-links. All visibilities are included because
///    intra-library inference can chain a private helper's inferred
///    type into a public one.
///
/// Offsets and other informative data are excluded on purpose: the
/// fingerprint backs an opt-in observation contract under which
/// builders never observe source positions.
///
/// Returns `null` when no sound fingerprint exists for the parse:
/// the unit did not parse cleanly (a degraded parse can silently drop
/// observable declarations, as augmentation syntax does under a
/// feature set that does not enable it), it uses library
/// augmentations, whose summary semantics are out of scope for cutoff
/// (ADR 0056), or the resolved analyzer's AST model does not behave
/// the way the walk expects (see [_astModelSupported]). Callers must
/// treat such units as content-keyed.
String? computeApiFingerprint(ParseStringResult result) {
  if (result.errors.isNotEmpty) return null;
  if (!_astModelSupported) return null;
  try {
    return _computeApiFingerprint(result);
  } on Object {
    // The AST model drifted from the shape the self-test validated.
    // Stop trusting it rather than risk a wrong fingerprint.
    _astModelSupportedOverride = false;
    return null;
  }
}

String? _computeApiFingerprint(ParseStringResult result) {
  final unit = result.unit;
  final walk = _walkUnit(unit);
  if (walk.usesAugmentation) return null;
  final apiSignature = computeUnlinkedApiSignature(
    unit as impl.CompilationUnitImpl,
  );
  final components = StringBuffer()
    ..writeln('api-fingerprint-v1')
    ..writeln(_hex(apiSignature))
    ..writeln(blake3Hex(utf8.encode(_docCommentSlots(unit, walk))))
    ..writeln(blake3Hex(utf8.encode(walk.omittedBodies.join('\n'))));
  return blake3Hex(utf8.encode(components.toString()));
}

/// Parses [content] and computes its API fingerprint.
///
/// This is the on-demand path; callers that already parse the unit for
/// the dependency walk should prefer [computeApiFingerprint] on the
/// shared parse.
String? apiFingerprintForContent(String content) {
  return computeApiFingerprint(
    parseString(content: content, throwIfDiagnostics: false),
  );
}

// ---------------------------------------------------------------------------
// AST model gate
//
// The declaration walk below deliberately uses only the AST surface
// that is stable across the supported analyzer window (pubspec.yaml):
// `AnnotatedNode` and its documentation comment, `MethodDeclaration`
// and `FunctionDeclaration` with their return type and setter flag,
// and `FunctionBody`. The window spans analyzer generations whose
// declaration classes give the same shapes different names, but this
// compatibility surface behaves the same in all of them (verified on
// 13.3, 14.5 and 14.6). A self-test on first use still verifies the
// walk's behavior on a sample library, so an intermediate release
// whose model drifted disables fingerprints instead of computing
// wrong ones.
// ---------------------------------------------------------------------------

bool? _astModelSupportedOverride;

/// Whether the walk behaves as expected on the resolved analyzer,
/// determined once per process by [_selfTestAstModel].
bool get _astModelSupported =>
    _astModelSupportedOverride ??= _selfTestAstModel();

/// Test hook: overrides the AST model gate. Production code never
/// calls this; tests use it to simulate an analyzer whose AST model
/// the walk cannot read, and restore the self-test result with null.
void debugSetAstModelSupported(bool? supported) {
  _astModelSupportedOverride = supported;
}

const _selfTestSource = '''
/// Sample class.
abstract class Sample {
  /// Method docs.
  void method(
    /// Param docs.
    int a,
  ) {}

  void abstractMethod(
    /// Abstract param docs.
    int a,
  );

  omitted() => 1;

  set setter(int v) {}
}

/// Sample enum.
enum SampleEnum {
  /// Constant docs.
  one,
  two,
}

topLevel() => 2;
''';

bool _selfTestAstModel() {
  try {
    final result = parseString(
      content: _selfTestSource,
      throwIfDiagnostics: false,
    );
    if (result.errors.isNotEmpty) return false;
    final walk = _walkUnit(result.unit);
    // The sample has exactly two executables with omitted return types
    // (the method and the top-level function); the setter and the typed
    // method must not be collected. Its doc comments must land in
    // slots, including the parameters' and the enum constant's.
    if (walk.omittedBodies.length != 2) return false;
    final slots = walk.docSlots.join('\n');
    return slots.contains('Method docs.') &&
        slots.contains('Param docs.') &&
        slots.contains('Abstract param docs.') &&
        slots.contains('Constant docs.');
  } on Object {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Declaration walk
// ---------------------------------------------------------------------------

final class _UnitWalk {
  final List<String> docSlots = <String>[];
  final Set<Token> consumedDocTokens = Set<Token>.identity();
  final List<String> omittedBodies = <String>[];
  bool usesAugmentation = false;
}

_UnitWalk _walkUnit(CompilationUnit unit) {
  final walk = _UnitWalk();
  for (final directive in unit.directives) {
    // A `library augment '...'` directive marks this unit as an
    // augmentation library. Under a feature set without augmentations
    // the URI is lost in recovery, leaving `augment` as the token
    // right after `library`.
    if (directive is LibraryDirective &&
        directive.libraryKeyword.next?.lexeme == 'augment') {
      walk.usesAugmentation = true;
    }
    // An `import augment '...'` directive means this library's API is
    // partly defined by another unit, so its own unit cannot carry a
    // complete fingerprint. The token right after `import` is the
    // augment keyword; configurations come later and cannot collide.
    if (directive is ImportDirective &&
        directive.importKeyword.next?.lexeme == 'augment') {
      walk.usesAugmentation = true;
    }
  }
  unit.visitChildren(_FingerprintVisitor(walk));
  return walk;
}

/// Collects the walk's doc slots and omitted-type bodies in one pass.
///
/// Every `AnnotatedNode` contributes one doc slot, in traversal order:
/// declarations, members, enum constants, type parameters and formal
/// parameters are all annotated nodes, so each doc comment is bound to
/// the node it documents. Function bodies are not descended into: a
/// body's own fingerprint contribution is decided from its owning
/// declaration, and nothing inside a body is part of the library's
/// observable API.
final class _FingerprintVisitor extends GeneralizingAstVisitor<void> {
  _FingerprintVisitor(this.walk);

  final _UnitWalk walk;

  @override
  void visitNode(AstNode node) {
    if (node is AnnotatedNode) {
      _slotDoc(node);
      // An augment declaration carries the `augment` keyword as its
      // first token after any comment and metadata. (A declaration
      // merely named `augment` with an omitted return type trips this
      // too; losing its fingerprint is safe, just conservative.)
      if (node.firstTokenAfterCommentAndMetadata.lexeme == 'augment') {
        walk.usesAugmentation = true;
      }
    }
    if (node is FunctionBody) {
      if (_isOmittedTypeExecutable(node)) {
        walk.omittedBodies.add(_bodyTokens(node));
      }
      return;
    }
    super.visitNode(node);
  }

  void _slotDoc(AnnotatedNode node) {
    final comment = node.documentationComment;
    if (comment == null) {
      walk.docSlots.add('');
      return;
    }
    walk.consumedDocTokens.addAll(comment.tokens);
    walk.docSlots.add(comment.tokens.map((token) => token.lexeme).join('\n'));
  }

  /// Whether [body] belongs to an executable whose return type is
  /// omitted. Constructors and setters are excluded: neither has an
  /// inferred return type a dependent could observe. Lambdas and
  /// local functions are not declarations of the library, so their
  /// bodies are excluded as well.
  bool _isOmittedTypeExecutable(FunctionBody body) {
    final parent = body.parent;
    if (parent is MethodDeclaration) {
      return parent.returnType == null && !parent.isSetter;
    }
    if (parent is FunctionExpression) {
      final owner = parent.parent;
      if (owner is FunctionDeclaration) {
        return owner.returnType == null && !owner.isSetter;
      }
    }
    return false;
  }
}

/// Token lexemes of [body], so comment edits and formatting inside it
/// stay invisible, matching the rest of the fingerprint.
String _bodyTokens(FunctionBody body) {
  final lexemes = StringBuffer();
  Token? token = body.beginToken;
  while (token != null) {
    lexemes
      ..write(token.lexeme)
      ..write(' ');
    if (token == body.endToken) break;
    final next = token.next;
    if (next == token) break;
    token = next;
  }
  return lexemes.toString();
}

/// The unit's doc comments as a slotted sequence: one slot per
/// annotated node in traversal order, holding its doc comment or
/// an empty marker, followed by any doc comments no traversed node
/// owns.
///
/// Slotting binds each comment to its node without names or offsets:
/// moving a comment from one declaration to another empties one slot
/// and fills the other, so the digest changes. Doc comments the
/// traversal does not reach (for example inside executable bodies,
/// which the walk does not descend into) are appended in token order
/// as a backstop, so no doc comment is ever dropped entirely. The
/// slots are JSON-encoded because doc text itself contains newlines:
/// a plain join would blur slot boundaries, and moving one doc line
/// between two documented declarations would go unnoticed.
String _docCommentSlots(CompilationUnit unit, _UnitWalk walk) {
  final unattached = <String>[];
  Token? token = unit.beginToken;
  while (token != null) {
    var comment = token.precedingComments;
    while (comment != null) {
      final lexeme = comment.lexeme;
      if ((lexeme.startsWith('///') || lexeme.startsWith('/**')) &&
          !walk.consumedDocTokens.contains(comment)) {
        unattached.add(lexeme);
      }
      comment = comment.next as CommentToken?;
    }
    final next = token.next;
    if (next == token) break;
    token = next;
  }
  return jsonEncode([walk.docSlots, unattached]);
}

String _hex(Uint8List bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Content-keyed persistent cache of API fingerprints.
///
/// Keyed by the content digest alone: unlike directive resolution, a
/// fingerprint depends only on the unit's own content. The store is
/// namespaced by SDK version because parsing is grammar-dependent,
/// and follows the same layout as the directive caches (ADR 0054).
/// A stored empty value marks a unit whose fingerprint is unavailable
/// (augmentations), so the parse is not repeated for it either.
///
/// Disable with `BUILD_RUNNER_ACCELERATOR_DEP_CACHE=0`, like the other
/// dep-parse caches.
final class ApiFingerprintCache {
  ApiFingerprintCache({IndexedBlobStore? store})
    : _store = store ?? _sharedStore();

  static const _packedVersion = 'v1';

  /// The shared process-wide cache, or `null` when disabled.
  static ApiFingerprintCache? shared() {
    if (Platform.environment['BUILD_RUNNER_ACCELERATOR_DEP_CACHE'] == '0') {
      return null;
    }
    return ApiFingerprintCache();
  }

  static IndexedBlobStore? _sharedStore() {
    if (Platform.environment['BUILD_RUNNER_ACCELERATOR_DEP_CACHE'] == '0') {
      return null;
    }
    final sdk = Platform.version.split(' ').first;
    return IndexedBlobStore(
      p.join(
        acceleratorCacheDirectory(),
        'api_fingerprint',
        '$_packedVersion-$sdk',
        'store.bin',
      ),
    );
  }

  final IndexedBlobStore? _store;

  /// The cached fingerprint for [contentDigest].
  ///
  /// Returns `null` both on a miss and for a stored unavailable marker
  /// (augmentations, parse errors); use [contains] to tell them apart.
  String? lookup(String contentDigest) {
    final bytes = _entry(contentDigest);
    if (bytes == null || bytes.isEmpty) return null;
    try {
      return utf8.decode(bytes);
    } on Object {
      return null;
    }
  }

  /// Whether any entry (fingerprint or unavailable marker) is stored
  /// for [contentDigest].
  bool contains(String contentDigest) => _entry(contentDigest) != null;

  /// Records [fingerprint] for [contentDigest]; `null` records the
  /// unavailable marker.
  void store(String contentDigest, String? fingerprint) {
    _store?.put(contentDigest, utf8.encode(fingerprint ?? ''));
  }

  /// The fingerprint for the unit with content digest [contentDigest]
  /// and source [content], computing and caching it on a miss.
  String? fingerprintFor(String contentDigest, String content) {
    if (_entry(contentDigest) != null) return lookup(contentDigest);
    final fingerprint = apiFingerprintForContent(content);
    // A null fingerprint is only worth persisting when the content
    // caused it (parse errors, augmentations). A null caused by the
    // AST model being unavailable in this process is environmental:
    // persisting it would mark valid content as unavailable for
    // later builds whose model works.
    if (fingerprint != null || _astModelSupported) {
      store(contentDigest, fingerprint);
    }
    return fingerprint;
  }

  Uint8List? _entry(String contentDigest) => _store?.get(contentDigest);
}
