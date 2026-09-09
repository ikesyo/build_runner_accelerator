import 'package:json_annotation/json_annotation.dart';

part 'model_250.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model250 {
  const Model250({required this.id, required this.value});

  final int id;
  final String value;

  factory Model250.fromJson(Map<String, dynamic> json) =>
      _$Model250FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model250ToJson(this);
}
