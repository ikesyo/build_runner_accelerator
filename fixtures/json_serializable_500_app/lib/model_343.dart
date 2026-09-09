import 'package:json_annotation/json_annotation.dart';

part 'model_343.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model343 {
  const Model343({required this.id, required this.value});

  final int id;
  final String value;

  factory Model343.fromJson(Map<String, dynamic> json) =>
      _$Model343FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model343ToJson(this);
}
