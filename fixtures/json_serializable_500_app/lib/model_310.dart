import 'package:json_annotation/json_annotation.dart';

part 'model_310.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model310 {
  const Model310({required this.id, required this.value});

  final int id;
  final String value;

  factory Model310.fromJson(Map<String, dynamic> json) =>
      _$Model310FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model310ToJson(this);
}
