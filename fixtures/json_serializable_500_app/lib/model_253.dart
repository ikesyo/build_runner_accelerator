import 'package:json_annotation/json_annotation.dart';

part 'model_253.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model253 {
  const Model253({required this.id, required this.value});

  final int id;
  final String value;

  factory Model253.fromJson(Map<String, dynamic> json) =>
      _$Model253FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model253ToJson(this);
}
