import 'package:json_annotation/json_annotation.dart';

part 'model_204.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model204 {
  const Model204({required this.id, required this.value});

  final int id;
  final String value;

  factory Model204.fromJson(Map<String, dynamic> json) =>
      _$Model204FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model204ToJson(this);
}
