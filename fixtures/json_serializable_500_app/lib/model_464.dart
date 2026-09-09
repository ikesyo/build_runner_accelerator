import 'package:json_annotation/json_annotation.dart';

part 'model_464.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model464 {
  const Model464({required this.id, required this.value});

  final int id;
  final String value;

  factory Model464.fromJson(Map<String, dynamic> json) =>
      _$Model464FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model464ToJson(this);
}
