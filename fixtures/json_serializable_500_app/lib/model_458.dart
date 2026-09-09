import 'package:json_annotation/json_annotation.dart';

part 'model_458.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model458 {
  const Model458({required this.id, required this.value});

  final int id;
  final String value;

  factory Model458.fromJson(Map<String, dynamic> json) =>
      _$Model458FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model458ToJson(this);
}
