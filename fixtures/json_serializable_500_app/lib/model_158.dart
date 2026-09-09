import 'package:json_annotation/json_annotation.dart';

part 'model_158.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model158 {
  const Model158({required this.id, required this.value});

  final int id;
  final String value;

  factory Model158.fromJson(Map<String, dynamic> json) =>
      _$Model158FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model158ToJson(this);
}
