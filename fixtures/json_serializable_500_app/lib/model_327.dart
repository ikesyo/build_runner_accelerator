import 'package:json_annotation/json_annotation.dart';

part 'model_327.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model327 {
  const Model327({required this.id, required this.value});

  final int id;
  final String value;

  factory Model327.fromJson(Map<String, dynamic> json) =>
      _$Model327FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model327ToJson(this);
}
