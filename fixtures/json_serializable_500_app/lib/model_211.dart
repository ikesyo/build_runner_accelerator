import 'package:json_annotation/json_annotation.dart';

part 'model_211.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model211 {
  const Model211({required this.id, required this.value});

  final int id;
  final String value;

  factory Model211.fromJson(Map<String, dynamic> json) =>
      _$Model211FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model211ToJson(this);
}
