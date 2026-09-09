import 'package:json_annotation/json_annotation.dart';

part 'model_056.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model056 {
  const Model056({required this.id, required this.value});

  final int id;
  final String value;

  factory Model056.fromJson(Map<String, dynamic> json) =>
      _$Model056FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model056ToJson(this);
}
