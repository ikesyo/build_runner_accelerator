import 'package:json_annotation/json_annotation.dart';

part 'model_293.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model293 {
  const Model293({required this.id, required this.value});

  final int id;
  final String value;

  factory Model293.fromJson(Map<String, dynamic> json) =>
      _$Model293FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model293ToJson(this);
}
