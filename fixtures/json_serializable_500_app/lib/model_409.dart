import 'package:json_annotation/json_annotation.dart';

part 'model_409.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model409 {
  const Model409({required this.id, required this.value});

  final int id;
  final String value;

  factory Model409.fromJson(Map<String, dynamic> json) =>
      _$Model409FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model409ToJson(this);
}
