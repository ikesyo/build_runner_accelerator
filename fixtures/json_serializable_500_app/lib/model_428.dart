import 'package:json_annotation/json_annotation.dart';

part 'model_428.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model428 {
  const Model428({required this.id, required this.value});

  final int id;
  final String value;

  factory Model428.fromJson(Map<String, dynamic> json) =>
      _$Model428FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model428ToJson(this);
}
