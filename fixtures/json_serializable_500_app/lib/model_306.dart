import 'package:json_annotation/json_annotation.dart';

part 'model_306.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model306 {
  const Model306({required this.id, required this.value});

  final int id;
  final String value;

  factory Model306.fromJson(Map<String, dynamic> json) =>
      _$Model306FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model306ToJson(this);
}
