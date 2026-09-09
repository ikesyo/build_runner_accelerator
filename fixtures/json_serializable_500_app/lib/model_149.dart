import 'package:json_annotation/json_annotation.dart';

part 'model_149.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model149 {
  const Model149({required this.id, required this.value});

  final int id;
  final String value;

  factory Model149.fromJson(Map<String, dynamic> json) =>
      _$Model149FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model149ToJson(this);
}
