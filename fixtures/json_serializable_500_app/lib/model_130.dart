import 'package:json_annotation/json_annotation.dart';

part 'model_130.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model130 {
  const Model130({required this.id, required this.value});

  final int id;
  final String value;

  factory Model130.fromJson(Map<String, dynamic> json) =>
      _$Model130FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model130ToJson(this);
}
