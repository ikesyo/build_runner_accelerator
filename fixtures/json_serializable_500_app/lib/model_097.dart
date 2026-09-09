import 'package:json_annotation/json_annotation.dart';

part 'model_097.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model097 {
  const Model097({required this.id, required this.value});

  final int id;
  final String value;

  factory Model097.fromJson(Map<String, dynamic> json) =>
      _$Model097FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model097ToJson(this);
}
