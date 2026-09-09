import 'package:json_annotation/json_annotation.dart';

part 'model_229.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model229 {
  const Model229({required this.id, required this.value});

  final int id;
  final String value;

  factory Model229.fromJson(Map<String, dynamic> json) =>
      _$Model229FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model229ToJson(this);
}
