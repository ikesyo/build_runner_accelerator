import 'package:json_annotation/json_annotation.dart';

part 'model_164.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model164 {
  const Model164({required this.id, required this.value});

  final int id;
  final String value;

  factory Model164.fromJson(Map<String, dynamic> json) =>
      _$Model164FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model164ToJson(this);
}
