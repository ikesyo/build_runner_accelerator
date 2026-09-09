import 'package:json_annotation/json_annotation.dart';

part 'model_424.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model424 {
  const Model424({required this.id, required this.value});

  final int id;
  final String value;

  factory Model424.fromJson(Map<String, dynamic> json) =>
      _$Model424FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model424ToJson(this);
}
