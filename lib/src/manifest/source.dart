/// Escapes a Dart string literal emitted into generated source code.
String dartSourceString(String value) {
  final output = StringBuffer("'");
  for (final codeUnit in value.codeUnits) {
    if (codeUnit == 0x5c || codeUnit == 0x27 || codeUnit == 0x24) {
      output
        ..write('\\')
        ..writeCharCode(codeUnit);
    } else if (codeUnit < 0x20 ||
        codeUnit == 0x7f ||
        codeUnit == 0x2028 ||
        codeUnit == 0x2029) {
      output
        ..write('\\u')
        ..write(codeUnit.toRadixString(16).padLeft(4, '0'));
    } else {
      output.writeCharCode(codeUnit);
    }
  }
  output.write("'");
  return output.toString();
}
