import 'package:json_annotation/json_annotation.dart';

part 'model_469.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model469 {
  const Model469({required this.id, required this.value});

  final int id;
  final String value;

  factory Model469.fromJson(Map<String, dynamic> json) =>
      _$Model469FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model469ToJson(this);
}
