import 'package:json_annotation/json_annotation.dart';

part 'model_426.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model426 {
  const Model426({required this.id, required this.value});

  final int id;
  final String value;

  factory Model426.fromJson(Map<String, dynamic> json) =>
      _$Model426FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model426ToJson(this);
}
