import 'package:json_annotation/json_annotation.dart';

part 'model_065.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model065 {
  const Model065({required this.id, required this.value});

  final int id;
  final String value;

  factory Model065.fromJson(Map<String, dynamic> json) =>
      _$Model065FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model065ToJson(this);
}
