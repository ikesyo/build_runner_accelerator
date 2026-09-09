import 'package:json_annotation/json_annotation.dart';

part 'model_381.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model381 {
  const Model381({required this.id, required this.value});

  final int id;
  final String value;

  factory Model381.fromJson(Map<String, dynamic> json) =>
      _$Model381FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model381ToJson(this);
}
