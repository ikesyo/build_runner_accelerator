import 'package:json_annotation/json_annotation.dart';

part 'model_486.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model486 {
  const Model486({required this.id, required this.value});

  final int id;
  final String value;

  factory Model486.fromJson(Map<String, dynamic> json) =>
      _$Model486FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model486ToJson(this);
}
