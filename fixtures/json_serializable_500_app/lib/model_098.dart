import 'package:json_annotation/json_annotation.dart';

part 'model_098.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model098 {
  const Model098({required this.id, required this.value});

  final int id;
  final String value;

  factory Model098.fromJson(Map<String, dynamic> json) =>
      _$Model098FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model098ToJson(this);
}
