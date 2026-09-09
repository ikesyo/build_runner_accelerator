import 'package:json_annotation/json_annotation.dart';

part 'model.g.dart';

@JsonSerializable()
class User {
  const User({required this.id, required this.displayName});

  final int id;
  final String displayName;

  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);

  Map<String, dynamic> toJson() => _$UserToJson(this);
}
