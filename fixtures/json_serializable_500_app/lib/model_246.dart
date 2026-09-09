import 'package:json_annotation/json_annotation.dart';

part 'model_246.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model246 {
  const Model246({required this.id, required this.value});

  final int id;
  final String value;

  factory Model246.fromJson(Map<String, dynamic> json) =>
      _$Model246FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model246ToJson(this);
}
