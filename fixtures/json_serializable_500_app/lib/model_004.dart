import 'package:json_annotation/json_annotation.dart';

part 'model_004.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model004 {
  const Model004({required this.id, required this.value});

  final int id;
  final String value;

  factory Model004.fromJson(Map<String, dynamic> json) =>
      _$Model004FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model004ToJson(this);
}
