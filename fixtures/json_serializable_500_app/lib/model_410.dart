import 'package:json_annotation/json_annotation.dart';

part 'model_410.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model410 {
  const Model410({required this.id, required this.value});

  final int id;
  final String value;

  factory Model410.fromJson(Map<String, dynamic> json) =>
      _$Model410FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model410ToJson(this);
}
