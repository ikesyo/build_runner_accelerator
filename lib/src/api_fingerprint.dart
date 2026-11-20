import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:pub_semver/pub_semver.dart';
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
/// 4. A digest of the field initializers of classes with a const
///    primary constructor. The analyzer signature hashes explicitly
///    typed field initializers only when it finds a traditional
///    const constructor, so a const primary constructor's fields
///    escape it, even though their values are observable through
///    constant evaluation of the constructor.
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
///
/// The parse must have been produced with the feature set of the
/// unit's package language version (see [apiFingerprintFeatureSet]):
/// the resolver parses units at that version and rejects what is
/// invalid there, so a fingerprint computed from a newer grammar
/// could bless an edit the real build would fail on.
/// [packageLanguageVersion] is that version ('3.10', say).
String? computeApiFingerprint(
  ParseStringResult result, {
  required String packageLanguageVersion,
}) {
  if (result.errors.isNotEmpty) return null;
  if (!_astModelSupported) return null;
  try {
    return _computeApiFingerprint(result, packageLanguageVersion);
  } on Object {
    // The AST model drifted from the shape the self-test validated.
    // Stop trusting it rather than risk a wrong fingerprint.
    _astModelSupportedOverride = false;
    return null;
  }
}

String? _computeApiFingerprint(
  ParseStringResult result,
  String packageLanguageVersion,
) {
  final unit = result.unit;
  final walk = _walkUnit(unit);
  if (walk.usesAugmentation) return null;
  final apiSignature = computeUnlinkedApiSignature(
    unit as impl.CompilationUnitImpl,
  );
  // The unit's language version is part of what the element model
  // exposes (LibraryElement's languageVersion) and can change how
  // the same declarations are interpreted, but it is not covered
  // by the API signature, so it is fingerprinted explicitly. The
  // package's configured version and the `// @dart = x.y` override
  // are recorded separately: the override's presence is itself
  // observable through the element model, even when it names the
  // same version the package already uses.
  final override = unit.languageVersionToken;
  final components = StringBuffer()
    ..writeln('api-fingerprint-v5')
    ..writeln(_hex(apiSignature))
    ..writeln(packageLanguageVersion)
    ..writeln(override == null ? '' : '${override.major}.${override.minor}')
    ..writeln(blake3Hex(utf8.encode(_docCommentSlots(unit, walk))))
    ..writeln(blake3Hex(utf8.encode(walk.omittedBodies.join('\n'))))
    ..writeln(blake3Hex(utf8.encode(walk.constPrimaryInitializers.join('\n'))));
  return blake3Hex(utf8.encode(components.toString()));
}

/// Test hook: the shared fingerprint store's directory segment for
/// the current SDK and [ApiFingerprintCache.sharedAnalyzerRoot].
String debugApiFingerprintStoreNamespace() =>
    ApiFingerprintCache._namespace(Platform.version.split(' ').first);

/// Parses [content] and computes its API fingerprint.
///
/// This is the on-demand path; callers that already parse the unit for
/// the dependency walk should prefer [computeApiFingerprint] on the
/// shared parse. Returns null when [package]'s language version was
/// not recorded (see [ApiFingerprintCache.packageLanguageVersions]):
/// without it the parse cannot be reproduced at the version the
/// resolver would use, so no sound fingerprint exists.
String? apiFingerprintForContent(String content, {required String package}) {
  final featureSet = apiFingerprintFeatureSet(package);
  final languageVersion = ApiFingerprintCache.packageLanguageVersions[package];
  if (featureSet == null || languageVersion == null) return null;
  return computeApiFingerprint(
    parseString(
      content: content,
      featureSet: featureSet,
      throwIfDiagnostics: false,
    ),
    packageLanguageVersion: languageVersion,
  );
}

final Map<String, FeatureSet> _featureSetByVersion = {};

/// The feature set the resolver parses [package]'s units with: the
/// features of its configured language version, which the parser
/// then restricts further for a unit's `// @dart =` override, exactly
/// as the analysis driver does. Null when the package's version was
/// not recorded.
FeatureSet? apiFingerprintFeatureSet(String package) {
  final version = ApiFingerprintCache.packageLanguageVersions[package];
  if (version == null) return null;
  return _featureSetByVersion[version] ??= FeatureSet.fromEnableFlags2(
    sdkLanguageVersion: _languageVersion(version),
    flags: const [],
  );
}

/// A recorded 'major.minor' language version as a [Version].
Version _languageVersion(String version) {
  final parts = version.split('.');
  return Version(
    int.parse(parts[0]),
    parts.length > 1 ? int.parse(parts[1]) : 0,
    0,
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
  final List<String> constPrimaryInitializers = <String>[];
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

  /// Whether the class whose body is currently being visited has a
  /// const primary constructor (see [_hasConstPrimaryConstructor]).
  bool _inConstPrimaryClass = false;

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final outer = _inConstPrimaryClass;
    if (_hasConstPrimaryConstructor(node)) _inConstPrimaryClass = true;
    super.visitClassDeclaration(node);
    _inConstPrimaryClass = outer;
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    if (_inConstPrimaryClass && !node.isStatic) {
      for (final variable in node.fields.variables) {
        final initializer = variable.initializer;
        if (initializer != null) {
          walk.constPrimaryInitializers.add(
            _tokenLexemes(initializer.beginToken, initializer.endToken),
          );
        }
      }
    }
    super.visitFieldDeclaration(node);
  }

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
String _bodyTokens(FunctionBody body) =>
    _tokenLexemes(body.beginToken, body.endToken);

/// Whether [node] declares a const primary constructor, detected
/// from the header tokens so the check works on any analyzer in the
/// supported window: a parameter list directly after the class name
/// (possibly after type parameters) marks a primary constructor,
/// and a `const` between the `class` keyword and that list makes
/// it const. Older grammars reject the syntax before this matters.
bool _hasConstPrimaryConstructor(ClassDeclaration node) {
  var sawConst = false;
  var angleDepth = 0;
  Token? token = node.classKeyword.next;
  while (token != null && token != node.endToken) {
    final lexeme = token.lexeme;
    // Type parameter lists (and function-typed bounds inside them)
    // contain their own parentheses and keywords; only depth-zero
    // tokens describe the constructor header itself.
    if (lexeme == '<') angleDepth++;
    if (lexeme == '>') angleDepth--;
    if (lexeme == '>>') angleDepth -= 2;
    if (lexeme == '>>>') angleDepth -= 3;
    if (angleDepth == 0) {
      if (lexeme == '(') return sawConst;
      if (lexeme == '{' ||
          lexeme == ';' ||
          lexeme == 'extends' ||
          lexeme == 'with' ||
          lexeme == 'implements') {
        return false;
      }
      if (lexeme == 'const') sawConst = true;
    }
    token = token.next;
  }
  return false;
}

/// Token lexemes between [begin] and [end] inclusive.
String _tokenLexemes(Token begin, Token end) {
  final lexemes = StringBuffer();
  Token? token = begin;
  while (token != null) {
    lexemes
      ..write(token.lexeme)
      ..write(' ');
    if (token == end) break;
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
/// Keyed by the content digest and the unit's package language
/// version: a fingerprint depends on the grammar the unit is parsed
/// with, and the same content in a package configured for an older
/// Dart can parse differently (or not at all). The store is
/// namespaced by SDK version because parsing is grammar-dependent,
/// and by the resolved analyzer (see [sharedAnalyzerRoot]) because
/// the fingerprint is computed by that analyzer's AST model; it
/// follows the same layout as the directive caches (ADR 0054).
/// A stored empty value marks a unit whose fingerprint is unavailable
/// (augmentations), so the parse is not repeated for it either.
///
/// Disable with `BUILD_RUNNER_ACCELERATOR_DEP_CACHE=0`, like the other
/// dep-parse caches.
/// A unit API fingerprint learned by the dep walk (ADR 0056), bound
/// to the bare BLAKE3 hex digest of the exact content that produced
/// it. A null [fingerprint] marks a unit whose fingerprint is
/// unavailable for that content.
typedef LearnedApiFingerprint = ({String digest, String? fingerprint});

final class ApiFingerprintCache {
  /// Whether the AST-model gate currently trusts fingerprinting in
  /// this process. The gate can close mid-process: fingerprinting a
  /// unit whose walk misbehaves latches it shut (see
  /// [computeApiFingerprint]), after which every fingerprint is
  /// unavailable. Callers that memoize fingerprints must consult
  /// this instead of serving a value learned before the gate closed.
  bool get modelSupported => _astModelSupported;

  ApiFingerprintCache({IndexedBlobStore? store})
    : _store = store ?? _sharedStore();

  /// Store format version, bumped whenever the fingerprint
  /// algorithm changes (v2: the language version override joined
  /// the fingerprint; v3: the effective language version is a
  /// component and entries are keyed by package language version;
  /// v4: const primary constructor field initializers joined the
  /// fingerprint; v5: the language version override is recorded
  /// separately from the package version), so entries computed by
  /// an older algorithm are never served for content they predate.
  static const _packedVersion = 'v5';

  /// Root URI of the resolved analyzer package, recorded from the
  /// project's package configuration by the worker's resolver setup,
  /// mirroring how the analysis byte store identifies the analyzer.
  ///
  /// Set before the first shared cache is built. A worker process
  /// serves one project, so the value is stable for its lifetime.
  static String? sharedAnalyzerRoot;

  /// Language versions ('3.10') by package name, recorded from the
  /// project's package configuration by the worker's resolver setup,
  /// with the SDK language version filled in for packages that do
  /// not configure one, mirroring how the analysis packages are
  /// built. A worker process serves one project, so the value is
  /// stable for its lifetime. Units of packages missing here get
  /// no fingerprint: their parse version cannot be reproduced.
  static Map<String, String> packageLanguageVersions = const {};

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
        _namespace(sdk),
        'store.bin',
      ),
    );
  }

  /// Store directory segment for [sdk]: the packed version and SDK,
  /// plus the analyzer package's directory name (which carries its
  /// version for hosted packages) and a digest of the complete root
  /// when the root is known. Distinct installs can share a directory
  /// name (two checkouts of a path dependency, say), and the digest
  /// keeps their fingerprints from mixing.
  static String _namespace(String sdk) {
    final base = '$_packedVersion-$sdk';
    final root = sharedAnalyzerRoot;
    if (root == null || root.isEmpty) return base;
    final segment = root.replaceAll(RegExp(r'/+$'), '').split('/').last;
    final sanitized = segment.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (sanitized.isEmpty) return base;
    final rootDigest = blake3Hex(utf8.encode(root)).substring(0, 8);
    return '$base-$sanitized-$rootDigest';
  }

  final IndexedBlobStore? _store;

  /// The store key for a unit: its content digest qualified by its
  /// package's language version. Null when the version was not
  /// recorded, in which case nothing is served or stored.
  String? _key(String contentDigest, String package) {
    final version = packageLanguageVersions[package];
    if (version == null) return null;
    return '$contentDigest@$version';
  }

  /// The cached fingerprint for the unit of [package] with content
  /// digest [contentDigest].
  ///
  /// Returns `null` both on a miss and for a stored unavailable marker
  /// (augmentations, parse errors); use [contains] to tell them apart.
  String? lookup(String contentDigest, {required String package}) {
    final key = _key(contentDigest, package);
    if (key == null) return null;
    final bytes = _entry(key);
    if (bytes == null || bytes.isEmpty) return null;
    try {
      return utf8.decode(bytes);
    } on Object {
      return null;
    }
  }

  /// Whether any entry (fingerprint or unavailable marker) is stored
  /// for the unit of [package] with content digest [contentDigest].
  bool contains(String contentDigest, {required String package}) {
    final key = _key(contentDigest, package);
    return key != null && _entry(key) != null;
  }

  /// Records [fingerprint] for the unit of [package] with content
  /// digest [contentDigest]; `null` records the unavailable marker.
  void store(
    String contentDigest,
    String? fingerprint, {
    required String package,
  }) {
    final key = _key(contentDigest, package);
    if (key == null) return;
    _store?.put(key, utf8.encode(fingerprint ?? ''));
  }

  /// The fingerprint for the unit of [package] with content digest
  /// [contentDigest] and source [content], computing and caching it
  /// on a miss.
  ///
  /// The AST-model gate applies to cache hits too: once the model is
  /// known not to behave, stored fingerprints are no longer trusted,
  /// because they were computed by the same walk.
  String? fingerprintFor(
    String contentDigest,
    String content, {
    required String package,
  }) {
    if (!_astModelSupported) return null;
    final key = _key(contentDigest, package);
    if (key == null) return null;
    if (_entry(key) != null) return lookup(contentDigest, package: package);
    final fingerprint = apiFingerprintForContent(content, package: package);
    // A null fingerprint is only worth persisting when the content
    // caused it (parse errors, augmentations). A null caused by the
    // AST model being unavailable in this process is environmental:
    // persisting it would mark valid content as unavailable for
    // later builds whose model works.
    if (fingerprint != null || _astModelSupported) {
      store(contentDigest, fingerprint, package: package);
    }
    return fingerprint;
  }

  /// The fingerprint for a unit of [package] the caller already
  /// parsed, recorded under [contentDigest]. The parse must have
  /// been produced with the package's feature set (see
  /// [apiFingerprintFeatureSet]). Follows the same rules as
  /// [fingerprintFor]: the AST-model gate applies before a stored
  /// entry is served, and an environment-caused null is not
  /// persisted as a marker.
  String? fingerprintForParse(
    String contentDigest,
    ParseStringResult result, {
    required String package,
  }) {
    if (!_astModelSupported) return null;
    final key = _key(contentDigest, package);
    if (key == null) return null;
    if (_entry(key) != null) return lookup(contentDigest, package: package);
    final fingerprint = computeApiFingerprint(
      result,
      packageLanguageVersion: packageLanguageVersions[package]!,
    );
    if (fingerprint != null || _astModelSupported) {
      store(contentDigest, fingerprint, package: package);
    }
    return fingerprint;
  }

  Uint8List? _entry(String key) => _store?.get(key);
}
