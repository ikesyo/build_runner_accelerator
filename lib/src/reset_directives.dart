/// A complete immutable decoded content version and its reset directive set.
/// Reuse requires equality of the entire String, not an asset, timestamp,
/// mutable buffer or AssetContent's optionally inherited digest.
final class ResetDirectiveContent {
  ResetDirectiveContent(String content)
    : this._(
        content,
        Set<String>.unmodifiable(
          pattern.allMatches(content).map((match) => match.group(0)!.trim()),
        ),
      );

  ResetDirectiveContent._(this.content, this.directives);

  final String content;
  final Set<String> directives;

  static final pattern = RegExp(
    r'''^\s*(?:import|export|part(?:\s+of)?|library)\s[^;]*;''',
    multiLine: true,
  );

  /// Bind the shared result to the supplied version; do not retain old text.
  ResetDirectiveContent? reuse(String content) => this.content == content
      ? ResetDirectiveContent._(content, directives)
      : null;
}
