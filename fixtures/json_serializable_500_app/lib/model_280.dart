import 'package:json_annotation/json_annotation.dart';

part 'model_280.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model280 {
  const Model280({required this.id, required this.value});

  final int id;
  final String value;

  factory Model280.fromJson(Map<String, dynamic> json) =>
      _$Model280FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model280ToJson(this);
}
