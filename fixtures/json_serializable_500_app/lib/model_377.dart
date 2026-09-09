import 'package:json_annotation/json_annotation.dart';

part 'model_377.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model377 {
  const Model377({required this.id, required this.value});

  final int id;
  final String value;

  factory Model377.fromJson(Map<String, dynamic> json) =>
      _$Model377FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model377ToJson(this);
}
