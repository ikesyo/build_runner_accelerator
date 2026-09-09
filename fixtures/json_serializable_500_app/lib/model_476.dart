import 'package:json_annotation/json_annotation.dart';

part 'model_476.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model476 {
  const Model476({required this.id, required this.value});

  final int id;
  final String value;

  factory Model476.fromJson(Map<String, dynamic> json) =>
      _$Model476FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model476ToJson(this);
}
