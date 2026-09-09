import 'package:json_annotation/json_annotation.dart';

part 'model_193.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model193 {
  const Model193({required this.id, required this.value});

  final int id;
  final String value;

  factory Model193.fromJson(Map<String, dynamic> json) =>
      _$Model193FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model193ToJson(this);
}
