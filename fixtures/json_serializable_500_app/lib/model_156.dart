import 'package:json_annotation/json_annotation.dart';

part 'model_156.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model156 {
  const Model156({required this.id, required this.value});

  final int id;
  final String value;

  factory Model156.fromJson(Map<String, dynamic> json) =>
      _$Model156FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model156ToJson(this);
}
