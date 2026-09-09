import 'package:json_annotation/json_annotation.dart';

part 'model_089.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model089 {
  const Model089({required this.id, required this.value});

  final int id;
  final String value;

  factory Model089.fromJson(Map<String, dynamic> json) =>
      _$Model089FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model089ToJson(this);
}
