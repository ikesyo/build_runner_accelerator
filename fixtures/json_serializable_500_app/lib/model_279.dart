import 'package:json_annotation/json_annotation.dart';

part 'model_279.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model279 {
  const Model279({required this.id, required this.value});

  final int id;
  final String value;

  factory Model279.fromJson(Map<String, dynamic> json) =>
      _$Model279FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model279ToJson(this);
}
