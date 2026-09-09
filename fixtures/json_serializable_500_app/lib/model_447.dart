import 'package:json_annotation/json_annotation.dart';

part 'model_447.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model447 {
  const Model447({required this.id, required this.value});

  final int id;
  final String value;

  factory Model447.fromJson(Map<String, dynamic> json) =>
      _$Model447FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model447ToJson(this);
}
