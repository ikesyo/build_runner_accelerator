import 'package:json_annotation/json_annotation.dart';

part 'model_051.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model051 {
  const Model051({required this.id, required this.value});

  final int id;
  final String value;

  factory Model051.fromJson(Map<String, dynamic> json) =>
      _$Model051FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model051ToJson(this);
}
