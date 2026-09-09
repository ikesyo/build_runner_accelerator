import 'package:json_annotation/json_annotation.dart';

part 'model_264.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model264 {
  const Model264({required this.id, required this.value});

  final int id;
  final String value;

  factory Model264.fromJson(Map<String, dynamic> json) =>
      _$Model264FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model264ToJson(this);
}
