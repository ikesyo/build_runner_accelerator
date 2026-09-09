import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'secondary.g.dart';

@riverpod
String greeting(Ref ref) => 'hello';
