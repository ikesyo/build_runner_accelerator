import 'package:json_annotation/json_annotation.dart';

part 'model_223.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model223 {
  const Model223({required this.id, required this.value});

  final int id;
  final String value;

  factory Model223.fromJson(Map<String, dynamic> json) =>
      _$Model223FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model223ToJson(this);
}
