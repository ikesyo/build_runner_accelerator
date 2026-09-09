import 'package:json_annotation/json_annotation.dart';

part 'model_201.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model201 {
  const Model201({required this.id, required this.value});

  final int id;
  final String value;

  factory Model201.fromJson(Map<String, dynamic> json) =>
      _$Model201FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model201ToJson(this);
}
