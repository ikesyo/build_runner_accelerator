import 'package:json_annotation/json_annotation.dart';

part 'model_473.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model473 {
  const Model473({required this.id, required this.value});

  final int id;
  final String value;

  factory Model473.fromJson(Map<String, dynamic> json) =>
      _$Model473FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model473ToJson(this);
}
