import 'package:json_annotation/json_annotation.dart';

part 'model_094.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model094 {
  const Model094({required this.id, required this.value});

  final int id;
  final String value;

  factory Model094.fromJson(Map<String, dynamic> json) =>
      _$Model094FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model094ToJson(this);
}
