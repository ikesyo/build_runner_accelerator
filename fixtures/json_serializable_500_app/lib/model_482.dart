import 'package:json_annotation/json_annotation.dart';

part 'model_482.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model482 {
  const Model482({required this.id, required this.value});

  final int id;
  final String value;

  factory Model482.fromJson(Map<String, dynamic> json) =>
      _$Model482FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model482ToJson(this);
}
