import 'package:json_annotation/json_annotation.dart';

part 'model_068.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model068 {
  const Model068({required this.id, required this.value});

  final int id;
  final String value;

  factory Model068.fromJson(Map<String, dynamic> json) =>
      _$Model068FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model068ToJson(this);
}
