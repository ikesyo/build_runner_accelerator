import 'package:json_annotation/json_annotation.dart';

part 'model_108.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model108 {
  const Model108({required this.id, required this.value});

  final int id;
  final String value;

  factory Model108.fromJson(Map<String, dynamic> json) =>
      _$Model108FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model108ToJson(this);
}
