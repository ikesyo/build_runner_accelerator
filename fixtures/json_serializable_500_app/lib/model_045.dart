import 'package:json_annotation/json_annotation.dart';

part 'model_045.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model045 {
  const Model045({required this.id, required this.value});

  final int id;
  final String value;

  factory Model045.fromJson(Map<String, dynamic> json) =>
      _$Model045FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model045ToJson(this);
}
