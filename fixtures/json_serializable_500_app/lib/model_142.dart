import 'package:json_annotation/json_annotation.dart';

part 'model_142.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model142 {
  const Model142({required this.id, required this.value});

  final int id;
  final String value;

  factory Model142.fromJson(Map<String, dynamic> json) =>
      _$Model142FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model142ToJson(this);
}
