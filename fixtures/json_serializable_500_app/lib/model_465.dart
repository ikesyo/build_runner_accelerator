import 'package:json_annotation/json_annotation.dart';

part 'model_465.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model465 {
  const Model465({required this.id, required this.value});

  final int id;
  final String value;

  factory Model465.fromJson(Map<String, dynamic> json) =>
      _$Model465FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model465ToJson(this);
}
