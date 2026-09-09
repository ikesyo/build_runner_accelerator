import 'package:json_annotation/json_annotation.dart';

part 'model_301.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model301 {
  const Model301({required this.id, required this.value});

  final int id;
  final String value;

  factory Model301.fromJson(Map<String, dynamic> json) =>
      _$Model301FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model301ToJson(this);
}
