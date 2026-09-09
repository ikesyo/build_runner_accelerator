import 'package:json_annotation/json_annotation.dart';

part 'model_148.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model148 {
  const Model148({required this.id, required this.value});

  final int id;
  final String value;

  factory Model148.fromJson(Map<String, dynamic> json) =>
      _$Model148FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model148ToJson(this);
}
