import 'package:json_annotation/json_annotation.dart';

part 'model_390.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model390 {
  const Model390({required this.id, required this.value});

  final int id;
  final String value;

  factory Model390.fromJson(Map<String, dynamic> json) =>
      _$Model390FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model390ToJson(this);
}
