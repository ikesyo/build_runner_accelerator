import 'package:json_annotation/json_annotation.dart';

part 'model_040.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model040 {
  const Model040({required this.id, required this.value});

  final int id;
  final String value;

  factory Model040.fromJson(Map<String, dynamic> json) =>
      _$Model040FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model040ToJson(this);
}
