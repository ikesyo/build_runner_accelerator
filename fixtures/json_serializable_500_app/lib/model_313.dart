import 'package:json_annotation/json_annotation.dart';

part 'model_313.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model313 {
  const Model313({required this.id, required this.value});

  final int id;
  final String value;

  factory Model313.fromJson(Map<String, dynamic> json) =>
      _$Model313FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model313ToJson(this);
}
