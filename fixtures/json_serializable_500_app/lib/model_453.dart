import 'package:json_annotation/json_annotation.dart';

part 'model_453.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model453 {
  const Model453({required this.id, required this.value});

  final int id;
  final String value;

  factory Model453.fromJson(Map<String, dynamic> json) =>
      _$Model453FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model453ToJson(this);
}
