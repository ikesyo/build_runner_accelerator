import 'package:json_annotation/json_annotation.dart';

part 'model_210.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model210 {
  const Model210({required this.id, required this.value});

  final int id;
  final String value;

  factory Model210.fromJson(Map<String, dynamic> json) =>
      _$Model210FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model210ToJson(this);
}
