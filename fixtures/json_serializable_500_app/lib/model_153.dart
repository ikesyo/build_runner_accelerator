import 'package:json_annotation/json_annotation.dart';

part 'model_153.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model153 {
  const Model153({required this.id, required this.value});

  final int id;
  final String value;

  factory Model153.fromJson(Map<String, dynamic> json) =>
      _$Model153FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model153ToJson(this);
}
