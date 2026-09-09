import 'package:json_annotation/json_annotation.dart';

part 'model_271.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model271 {
  const Model271({required this.id, required this.value});

  final int id;
  final String value;

  factory Model271.fromJson(Map<String, dynamic> json) =>
      _$Model271FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model271ToJson(this);
}
