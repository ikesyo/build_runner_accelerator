import 'package:json_annotation/json_annotation.dart';

part 'model_282.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model282 {
  const Model282({required this.id, required this.value});

  final int id;
  final String value;

  factory Model282.fromJson(Map<String, dynamic> json) =>
      _$Model282FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model282ToJson(this);
}
