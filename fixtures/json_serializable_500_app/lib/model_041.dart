import 'package:json_annotation/json_annotation.dart';

part 'model_041.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model041 {
  const Model041({required this.id, required this.value});

  final int id;
  final String value;

  factory Model041.fromJson(Map<String, dynamic> json) =>
      _$Model041FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model041ToJson(this);
}
