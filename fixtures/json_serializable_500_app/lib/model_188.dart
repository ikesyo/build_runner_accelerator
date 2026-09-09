import 'package:json_annotation/json_annotation.dart';

part 'model_188.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model188 {
  const Model188({required this.id, required this.value});

  final int id;
  final String value;

  factory Model188.fromJson(Map<String, dynamic> json) =>
      _$Model188FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model188ToJson(this);
}
