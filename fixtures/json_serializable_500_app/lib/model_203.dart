import 'package:json_annotation/json_annotation.dart';

part 'model_203.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model203 {
  const Model203({required this.id, required this.value});

  final int id;
  final String value;

  factory Model203.fromJson(Map<String, dynamic> json) =>
      _$Model203FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model203ToJson(this);
}
