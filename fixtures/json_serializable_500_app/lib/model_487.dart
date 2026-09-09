import 'package:json_annotation/json_annotation.dart';

part 'model_487.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model487 {
  const Model487({required this.id, required this.value});

  final int id;
  final String value;

  factory Model487.fromJson(Map<String, dynamic> json) =>
      _$Model487FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model487ToJson(this);
}
