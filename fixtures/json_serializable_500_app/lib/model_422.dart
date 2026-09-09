import 'package:json_annotation/json_annotation.dart';

part 'model_422.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model422 {
  const Model422({required this.id, required this.value});

  final int id;
  final String value;

  factory Model422.fromJson(Map<String, dynamic> json) =>
      _$Model422FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model422ToJson(this);
}
