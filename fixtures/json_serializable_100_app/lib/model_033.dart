import 'package:json_annotation/json_annotation.dart';

part 'model_033.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model033 {
  const Model033({required this.id, required this.value});

  final int id;
  final String value;

  factory Model033.fromJson(Map<String, dynamic> json) =>
      _$Model033FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model033ToJson(this);
}
