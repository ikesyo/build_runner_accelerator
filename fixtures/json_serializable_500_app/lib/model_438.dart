import 'package:json_annotation/json_annotation.dart';

part 'model_438.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model438 {
  const Model438({required this.id, required this.value});

  final int id;
  final String value;

  factory Model438.fromJson(Map<String, dynamic> json) =>
      _$Model438FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model438ToJson(this);
}
