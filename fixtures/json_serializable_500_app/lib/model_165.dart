import 'package:json_annotation/json_annotation.dart';

part 'model_165.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model165 {
  const Model165({required this.id, required this.value});

  final int id;
  final String value;

  factory Model165.fromJson(Map<String, dynamic> json) =>
      _$Model165FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model165ToJson(this);
}
