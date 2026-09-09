import 'package:json_annotation/json_annotation.dart';

part 'model_154.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model154 {
  const Model154({required this.id, required this.value});

  final int id;
  final String value;

  factory Model154.fromJson(Map<String, dynamic> json) =>
      _$Model154FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model154ToJson(this);
}
