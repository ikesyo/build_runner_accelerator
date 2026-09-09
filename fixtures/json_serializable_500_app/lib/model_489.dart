import 'package:json_annotation/json_annotation.dart';

part 'model_489.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model489 {
  const Model489({required this.id, required this.value});

  final int id;
  final String value;

  factory Model489.fromJson(Map<String, dynamic> json) =>
      _$Model489FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model489ToJson(this);
}
