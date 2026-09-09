import 'package:json_annotation/json_annotation.dart';

part 'model_159.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model159 {
  const Model159({required this.id, required this.value});

  final int id;
  final String value;

  factory Model159.fromJson(Map<String, dynamic> json) =>
      _$Model159FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model159ToJson(this);
}
