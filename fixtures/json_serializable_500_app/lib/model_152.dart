import 'package:json_annotation/json_annotation.dart';

part 'model_152.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model152 {
  const Model152({required this.id, required this.value});

  final int id;
  final String value;

  factory Model152.fromJson(Map<String, dynamic> json) =>
      _$Model152FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model152ToJson(this);
}
