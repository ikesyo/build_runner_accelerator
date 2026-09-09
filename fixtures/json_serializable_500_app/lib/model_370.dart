import 'package:json_annotation/json_annotation.dart';

part 'model_370.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model370 {
  const Model370({required this.id, required this.value});

  final int id;
  final String value;

  factory Model370.fromJson(Map<String, dynamic> json) =>
      _$Model370FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model370ToJson(this);
}
