import 'package:json_annotation/json_annotation.dart';

part 'model_285.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model285 {
  const Model285({required this.id, required this.value});

  final int id;
  final String value;

  factory Model285.fromJson(Map<String, dynamic> json) =>
      _$Model285FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model285ToJson(this);
}
