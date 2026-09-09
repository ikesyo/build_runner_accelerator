import 'package:json_annotation/json_annotation.dart';

part 'model_423.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model423 {
  const Model423({required this.id, required this.value});

  final int id;
  final String value;

  factory Model423.fromJson(Map<String, dynamic> json) =>
      _$Model423FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model423ToJson(this);
}
