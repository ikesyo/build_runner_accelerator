import 'package:json_annotation/json_annotation.dart';

part 'model_272.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model272 {
  const Model272({required this.id, required this.value});

  final int id;
  final String value;

  factory Model272.fromJson(Map<String, dynamic> json) =>
      _$Model272FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model272ToJson(this);
}
