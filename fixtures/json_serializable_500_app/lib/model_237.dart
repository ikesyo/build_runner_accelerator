import 'package:json_annotation/json_annotation.dart';

part 'model_237.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model237 {
  const Model237({required this.id, required this.value});

  final int id;
  final String value;

  factory Model237.fromJson(Map<String, dynamic> json) =>
      _$Model237FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model237ToJson(this);
}
