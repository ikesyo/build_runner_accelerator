import 'package:json_annotation/json_annotation.dart';

part 'model_115.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model115 {
  const Model115({required this.id, required this.value});

  final int id;
  final String value;

  factory Model115.fromJson(Map<String, dynamic> json) =>
      _$Model115FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model115ToJson(this);
}
