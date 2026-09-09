import 'package:json_annotation/json_annotation.dart';

part 'model_134.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model134 {
  const Model134({required this.id, required this.value});

  final int id;
  final String value;

  factory Model134.fromJson(Map<String, dynamic> json) =>
      _$Model134FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model134ToJson(this);
}
