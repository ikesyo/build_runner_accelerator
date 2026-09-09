import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'model.freezed.dart';
part 'model.g.dart';

@riverpod
int answer(Ref ref) => 42;

@freezed
abstract class Profile with _$Profile {
  const factory Profile({required String label}) = _Profile;
}

@JsonSerializable()
class User {
  const User({required this.id, required this.displayName});

  final int id;
  final String displayName;

  factory User.fromJson(Map<String, Object?> json) => _$UserFromJson(json);

  Map<String, Object?> toJson() => _$UserToJson(this);
}
