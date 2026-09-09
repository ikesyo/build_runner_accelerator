import 'package:json_annotation/json_annotation.dart';

part 'model_032.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model032 {
  const Model032({required this.id, required this.value});

  final int id;
  final String value;

  factory Model032.fromJson(Map<String, dynamic> json) =>
      _$Model032FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model032ToJson(this);
}
