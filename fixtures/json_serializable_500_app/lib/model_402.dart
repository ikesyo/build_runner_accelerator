import 'package:json_annotation/json_annotation.dart';

part 'model_402.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model402 {
  const Model402({required this.id, required this.value});

  final int id;
  final String value;

  factory Model402.fromJson(Map<String, dynamic> json) =>
      _$Model402FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model402ToJson(this);
}
