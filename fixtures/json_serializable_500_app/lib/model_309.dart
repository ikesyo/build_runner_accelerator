import 'package:json_annotation/json_annotation.dart';

part 'model_309.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model309 {
  const Model309({required this.id, required this.value});

  final int id;
  final String value;

  factory Model309.fromJson(Map<String, dynamic> json) =>
      _$Model309FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model309ToJson(this);
}
