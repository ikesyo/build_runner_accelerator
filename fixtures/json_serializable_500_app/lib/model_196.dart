import 'package:json_annotation/json_annotation.dart';

part 'model_196.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model196 {
  const Model196({required this.id, required this.value});

  final int id;
  final String value;

  factory Model196.fromJson(Map<String, dynamic> json) =>
      _$Model196FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model196ToJson(this);
}
