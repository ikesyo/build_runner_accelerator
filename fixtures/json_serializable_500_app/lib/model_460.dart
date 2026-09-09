import 'package:json_annotation/json_annotation.dart';

part 'model_460.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model460 {
  const Model460({required this.id, required this.value});

  final int id;
  final String value;

  factory Model460.fromJson(Map<String, dynamic> json) =>
      _$Model460FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model460ToJson(this);
}
