import 'package:json_annotation/json_annotation.dart';

part 'model_414.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model414 {
  const Model414({required this.id, required this.value});

  final int id;
  final String value;

  factory Model414.fromJson(Map<String, dynamic> json) =>
      _$Model414FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model414ToJson(this);
}
