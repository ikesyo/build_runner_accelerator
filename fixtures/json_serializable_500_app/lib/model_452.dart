import 'package:json_annotation/json_annotation.dart';

part 'model_452.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model452 {
  const Model452({required this.id, required this.value});

  final int id;
  final String value;

  factory Model452.fromJson(Map<String, dynamic> json) =>
      _$Model452FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model452ToJson(this);
}
