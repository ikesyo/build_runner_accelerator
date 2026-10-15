/// A conservative lexical subset of stock BuildFilter.fromArg / Glob.
/// Unsupported URI/glob syntax is routed before native acquisition.
class NativeBuildFilter {
  static void parse(String value) {
    if (value.isEmpty || RegExp(r'[^a-zA-Z0-9_./*:-]').hasMatch(value)) {
      throw FormatException('Unsupported native build filter: $value');
    }
    var path = value;
    if (value.contains(':')) {
      if (!value.startsWith('package:') && !value.startsWith('asset:')) {
        throw FormatException('Unsupported build filter scheme: $value');
      }
      path = value.substring(value.indexOf(':') + 1);
      if (value.startsWith('asset:') && !path.contains('/')) {
        throw FormatException('Asset filter requires a path: $value');
      }
      if (path.isEmpty ||
          path.startsWith('/') ||
          path.endsWith('/') ||
          path.contains(':')) {
        throw FormatException('Unsupported build filter URI: $value');
      }
    }
    if (path.startsWith('/') ||
        path.endsWith('/') ||
        path.contains('//') ||
        path
            .split('/')
            .any(
              (part) =>
                  part == '.' ||
                  part == '..' ||
                  (part.contains('**') && part != '**'),
            )) {
      throw FormatException('Unsupported native build filter path: $value');
    }
  }
}
