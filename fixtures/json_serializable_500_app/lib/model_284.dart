import 'package:json_annotation/json_annotation.dart';

part 'model_284.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model284 {
  const Model284({required this.id, required this.value});

  final int id;
  final String value;

  factory Model284.fromJson(Map<String, dynamic> json) =>
      _$Model284FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model284ToJson(this);
}
