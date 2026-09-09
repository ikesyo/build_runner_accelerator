import 'package:json_annotation/json_annotation.dart';

part 'model_198.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model198 {
  const Model198({required this.id, required this.value});

  final int id;
  final String value;

  factory Model198.fromJson(Map<String, dynamic> json) =>
      _$Model198FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model198ToJson(this);
}
