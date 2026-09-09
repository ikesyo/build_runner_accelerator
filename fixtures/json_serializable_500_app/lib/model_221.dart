import 'package:json_annotation/json_annotation.dart';

part 'model_221.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model221 {
  const Model221({required this.id, required this.value});

  final int id;
  final String value;

  factory Model221.fromJson(Map<String, dynamic> json) =>
      _$Model221FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model221ToJson(this);
}
