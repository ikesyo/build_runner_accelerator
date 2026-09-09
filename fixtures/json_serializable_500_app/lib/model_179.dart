import 'package:json_annotation/json_annotation.dart';

part 'model_179.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model179 {
  const Model179({required this.id, required this.value});

  final int id;
  final String value;

  factory Model179.fromJson(Map<String, dynamic> json) =>
      _$Model179FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model179ToJson(this);
}
