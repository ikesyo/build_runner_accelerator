import 'package:json_annotation/json_annotation.dart';

part 'model_013.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model013 {
  const Model013({required this.id, required this.value});

  final int id;
  final String value;

  factory Model013.fromJson(Map<String, dynamic> json) =>
      _$Model013FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model013ToJson(this);
}
