import 'package:json_annotation/json_annotation.dart';

part 'model_114.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model114 {
  const Model114({required this.id, required this.value});

  final int id;
  final String value;

  factory Model114.fromJson(Map<String, dynamic> json) =>
      _$Model114FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model114ToJson(this);
}
