import 'package:json_annotation/json_annotation.dart';

part 'model_091.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model091 {
  const Model091({required this.id, required this.value});

  final int id;
  final String value;

  factory Model091.fromJson(Map<String, dynamic> json) =>
      _$Model091FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model091ToJson(this);
}
