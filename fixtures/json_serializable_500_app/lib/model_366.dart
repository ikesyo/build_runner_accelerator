import 'package:json_annotation/json_annotation.dart';

part 'model_366.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model366 {
  const Model366({required this.id, required this.value});

  final int id;
  final String value;

  factory Model366.fromJson(Map<String, dynamic> json) =>
      _$Model366FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model366ToJson(this);
}
