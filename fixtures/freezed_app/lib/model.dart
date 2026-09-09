import 'package:freezed_annotation/freezed_annotation.dart';

part 'model.freezed.dart';

@freezed
abstract class User with _$User {
  const factory User({
    required int id,
    required String displayName,
  }) = _User;
}
