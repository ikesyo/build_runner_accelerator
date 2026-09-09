import 'package:json_annotation/json_annotation.dart';

part 'model_376.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model376 {
  const Model376({required this.id, required this.value});

  final int id;
  final String value;

  factory Model376.fromJson(Map<String, dynamic> json) =>
      _$Model376FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model376ToJson(this);
}
