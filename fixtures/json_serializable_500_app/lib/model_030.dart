import 'package:json_annotation/json_annotation.dart';

part 'model_030.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model030 {
  const Model030({required this.id, required this.value});

  final int id;
  final String value;

  factory Model030.fromJson(Map<String, dynamic> json) =>
      _$Model030FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model030ToJson(this);
}
