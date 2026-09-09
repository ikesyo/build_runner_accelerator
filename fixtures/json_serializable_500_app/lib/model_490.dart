import 'package:json_annotation/json_annotation.dart';

part 'model_490.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model490 {
  const Model490({required this.id, required this.value});

  final int id;
  final String value;

  factory Model490.fromJson(Map<String, dynamic> json) =>
      _$Model490FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model490ToJson(this);
}
