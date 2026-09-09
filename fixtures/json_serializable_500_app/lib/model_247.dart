import 'package:json_annotation/json_annotation.dart';

part 'model_247.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model247 {
  const Model247({required this.id, required this.value});

  final int id;
  final String value;

  factory Model247.fromJson(Map<String, dynamic> json) =>
      _$Model247FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model247ToJson(this);
}
