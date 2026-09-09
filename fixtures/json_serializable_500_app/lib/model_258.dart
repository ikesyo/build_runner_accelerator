import 'package:json_annotation/json_annotation.dart';

part 'model_258.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model258 {
  const Model258({required this.id, required this.value});

  final int id;
  final String value;

  factory Model258.fromJson(Map<String, dynamic> json) =>
      _$Model258FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model258ToJson(this);
}
