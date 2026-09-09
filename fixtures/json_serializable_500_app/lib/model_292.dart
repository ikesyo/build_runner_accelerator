import 'package:json_annotation/json_annotation.dart';

part 'model_292.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model292 {
  const Model292({required this.id, required this.value});

  final int id;
  final String value;

  factory Model292.fromJson(Map<String, dynamic> json) =>
      _$Model292FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model292ToJson(this);
}
