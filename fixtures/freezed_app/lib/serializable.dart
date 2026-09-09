import 'package:freezed_annotation/freezed_annotation.dart';

part 'serializable.freezed.dart';
part 'serializable.g.dart';

@freezed
abstract class SerializableUser with _$SerializableUser {
  const factory SerializableUser({
    required int id,
    required String displayName,
  }) = _SerializableUser;

  factory SerializableUser.fromJson(Map<String, Object?> json) =>
      _$SerializableUserFromJson(json);
}
