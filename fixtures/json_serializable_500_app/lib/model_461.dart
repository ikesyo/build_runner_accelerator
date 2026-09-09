import 'package:json_annotation/json_annotation.dart';

part 'model_461.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model461 {
  const Model461({required this.id, required this.value});

  final int id;
  final String value;

  factory Model461.fromJson(Map<String, dynamic> json) =>
      _$Model461FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model461ToJson(this);
}
