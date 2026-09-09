import 'package:json_annotation/json_annotation.dart';

part 'model_491.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model491 {
  const Model491({required this.id, required this.value});

  final int id;
  final String value;

  factory Model491.fromJson(Map<String, dynamic> json) =>
      _$Model491FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model491ToJson(this);
}
