import 'package:json_annotation/json_annotation.dart';

part 'model_088.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model088 {
  const Model088({required this.id, required this.value});

  final int id;
  final String value;

  factory Model088.fromJson(Map<String, dynamic> json) =>
      _$Model088FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model088ToJson(this);
}
