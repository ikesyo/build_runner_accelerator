import 'package:json_annotation/json_annotation.dart';

part 'model_358.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model358 {
  const Model358({required this.id, required this.value});

  final int id;
  final String value;

  factory Model358.fromJson(Map<String, dynamic> json) =>
      _$Model358FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model358ToJson(this);
}
