import 'package:json_annotation/json_annotation.dart';

part 'model_194.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model194 {
  const Model194({required this.id, required this.value});

  final int id;
  final String value;

  factory Model194.fromJson(Map<String, dynamic> json) =>
      _$Model194FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model194ToJson(this);
}
