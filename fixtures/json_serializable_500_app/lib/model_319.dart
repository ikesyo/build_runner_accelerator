import 'package:json_annotation/json_annotation.dart';

part 'model_319.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model319 {
  const Model319({required this.id, required this.value});

  final int id;
  final String value;

  factory Model319.fromJson(Map<String, dynamic> json) =>
      _$Model319FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model319ToJson(this);
}
