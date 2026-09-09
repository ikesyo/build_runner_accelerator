import 'package:json_annotation/json_annotation.dart';

part 'model_372.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model372 {
  const Model372({required this.id, required this.value});

  final int id;
  final String value;

  factory Model372.fromJson(Map<String, dynamic> json) =>
      _$Model372FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model372ToJson(this);
}
