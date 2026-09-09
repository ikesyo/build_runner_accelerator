import 'package:json_annotation/json_annotation.dart';

part 'model_187.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model187 {
  const Model187({required this.id, required this.value});

  final int id;
  final String value;

  factory Model187.fromJson(Map<String, dynamic> json) =>
      _$Model187FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model187ToJson(this);
}
