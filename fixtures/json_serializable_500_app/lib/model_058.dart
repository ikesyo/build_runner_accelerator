import 'package:json_annotation/json_annotation.dart';

part 'model_058.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model058 {
  const Model058({required this.id, required this.value});

  final int id;
  final String value;

  factory Model058.fromJson(Map<String, dynamic> json) =>
      _$Model058FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model058ToJson(this);
}
