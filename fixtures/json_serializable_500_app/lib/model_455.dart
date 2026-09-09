import 'package:json_annotation/json_annotation.dart';

part 'model_455.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model455 {
  const Model455({required this.id, required this.value});

  final int id;
  final String value;

  factory Model455.fromJson(Map<String, dynamic> json) =>
      _$Model455FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model455ToJson(this);
}
