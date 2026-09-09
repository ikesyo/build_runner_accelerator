import 'package:json_annotation/json_annotation.dart';

part 'model_415.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model415 {
  const Model415({required this.id, required this.value});

  final int id;
  final String value;

  factory Model415.fromJson(Map<String, dynamic> json) =>
      _$Model415FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model415ToJson(this);
}
