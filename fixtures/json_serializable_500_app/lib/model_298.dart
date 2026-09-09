import 'package:json_annotation/json_annotation.dart';

part 'model_298.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model298 {
  const Model298({required this.id, required this.value});

  final int id;
  final String value;

  factory Model298.fromJson(Map<String, dynamic> json) =>
      _$Model298FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model298ToJson(this);
}
