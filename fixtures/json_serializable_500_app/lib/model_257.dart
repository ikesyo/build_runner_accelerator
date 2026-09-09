import 'package:json_annotation/json_annotation.dart';

part 'model_257.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model257 {
  const Model257({required this.id, required this.value});

  final int id;
  final String value;

  factory Model257.fromJson(Map<String, dynamic> json) =>
      _$Model257FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model257ToJson(this);
}
