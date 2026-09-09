import 'package:json_annotation/json_annotation.dart';

part 'model_175.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model175 {
  const Model175({required this.id, required this.value});

  final int id;
  final String value;

  factory Model175.fromJson(Map<String, dynamic> json) =>
      _$Model175FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model175ToJson(this);
}
