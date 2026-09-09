import 'package:json_annotation/json_annotation.dart';

part 'model_317.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model317 {
  const Model317({required this.id, required this.value});

  final int id;
  final String value;

  factory Model317.fromJson(Map<String, dynamic> json) =>
      _$Model317FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model317ToJson(this);
}
