import 'package:json_annotation/json_annotation.dart';

part 'model_052.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model052 {
  const Model052({required this.id, required this.value});

  final int id;
  final String value;

  factory Model052.fromJson(Map<String, dynamic> json) =>
      _$Model052FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model052ToJson(this);
}
