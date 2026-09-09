import 'package:json_annotation/json_annotation.dart';

part 'model_307.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model307 {
  const Model307({required this.id, required this.value});

  final int id;
  final String value;

  factory Model307.fromJson(Map<String, dynamic> json) =>
      _$Model307FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model307ToJson(this);
}
