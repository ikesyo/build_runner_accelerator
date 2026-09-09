import 'package:json_annotation/json_annotation.dart';

part 'model_231.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model231 {
  const Model231({required this.id, required this.value});

  final int id;
  final String value;

  factory Model231.fromJson(Map<String, dynamic> json) =>
      _$Model231FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model231ToJson(this);
}
