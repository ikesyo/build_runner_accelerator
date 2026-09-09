import 'package:json_annotation/json_annotation.dart';

part 'model_124.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model124 {
  const Model124({required this.id, required this.value});

  final int id;
  final String value;

  factory Model124.fromJson(Map<String, dynamic> json) =>
      _$Model124FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model124ToJson(this);
}
