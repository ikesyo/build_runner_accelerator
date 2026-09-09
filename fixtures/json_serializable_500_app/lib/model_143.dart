import 'package:json_annotation/json_annotation.dart';

part 'model_143.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model143 {
  const Model143({required this.id, required this.value});

  final int id;
  final String value;

  factory Model143.fromJson(Map<String, dynamic> json) =>
      _$Model143FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model143ToJson(this);
}
