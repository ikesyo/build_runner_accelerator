import 'package:json_annotation/json_annotation.dart';

part 'model_139.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model139 {
  const Model139({required this.id, required this.value});

  final int id;
  final String value;

  factory Model139.fromJson(Map<String, dynamic> json) =>
      _$Model139FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model139ToJson(this);
}
