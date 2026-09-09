import 'package:json_annotation/json_annotation.dart';

part 'model_084.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model084 {
  const Model084({required this.id, required this.value});

  final int id;
  final String value;

  factory Model084.fromJson(Map<String, dynamic> json) =>
      _$Model084FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model084ToJson(this);
}
