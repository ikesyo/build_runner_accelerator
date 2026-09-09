import 'package:json_annotation/json_annotation.dart';

part 'model_457.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model457 {
  const Model457({required this.id, required this.value});

  final int id;
  final String value;

  factory Model457.fromJson(Map<String, dynamic> json) =>
      _$Model457FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model457ToJson(this);
}
