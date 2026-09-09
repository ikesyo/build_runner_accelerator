import 'package:json_annotation/json_annotation.dart';

part 'model_320.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model320 {
  const Model320({required this.id, required this.value});

  final int id;
  final String value;

  factory Model320.fromJson(Map<String, dynamic> json) =>
      _$Model320FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model320ToJson(this);
}
