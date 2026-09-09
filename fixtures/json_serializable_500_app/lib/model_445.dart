import 'package:json_annotation/json_annotation.dart';

part 'model_445.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model445 {
  const Model445({required this.id, required this.value});

  final int id;
  final String value;

  factory Model445.fromJson(Map<String, dynamic> json) =>
      _$Model445FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model445ToJson(this);
}
