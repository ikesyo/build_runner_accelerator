import 'package:json_annotation/json_annotation.dart';

part 'model_190.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model190 {
  const Model190({required this.id, required this.value});

  final int id;
  final String value;

  factory Model190.fromJson(Map<String, dynamic> json) =>
      _$Model190FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model190ToJson(this);
}
