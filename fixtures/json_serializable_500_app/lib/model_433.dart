import 'package:json_annotation/json_annotation.dart';

part 'model_433.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model433 {
  const Model433({required this.id, required this.value});

  final int id;
  final String value;

  factory Model433.fromJson(Map<String, dynamic> json) =>
      _$Model433FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model433ToJson(this);
}
