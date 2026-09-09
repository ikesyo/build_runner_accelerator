import 'package:json_annotation/json_annotation.dart';

part 'model_339.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model339 {
  const Model339({required this.id, required this.value});

  final int id;
  final String value;

  factory Model339.fromJson(Map<String, dynamic> json) =>
      _$Model339FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model339ToJson(this);
}
