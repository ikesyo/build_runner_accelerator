import 'package:json_annotation/json_annotation.dart';

part 'model_10.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model10 {
  const Model10({required this.id, required this.value});

  final int id;
  final String value;

  factory Model10.fromJson(Map<String, dynamic> json) =>
      _$Model10FromJson(json);

  Map<String, dynamic> toJson() => _$Model10ToJson(this);
}
