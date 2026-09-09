import 'package:json_annotation/json_annotation.dart';

part 'model_494.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model494 {
  const Model494({required this.id, required this.value});

  final int id;
  final String value;

  factory Model494.fromJson(Map<String, dynamic> json) =>
      _$Model494FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model494ToJson(this);
}
