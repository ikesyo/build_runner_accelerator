import 'package:json_annotation/json_annotation.dart';

part 'model_430.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model430 {
  const Model430({required this.id, required this.value});

  final int id;
  final String value;

  factory Model430.fromJson(Map<String, dynamic> json) =>
      _$Model430FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model430ToJson(this);
}
