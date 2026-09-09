import 'package:json_annotation/json_annotation.dart';

part 'model_106.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model106 {
  const Model106({required this.id, required this.value});

  final int id;
  final String value;

  factory Model106.fromJson(Map<String, dynamic> json) =>
      _$Model106FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model106ToJson(this);
}
