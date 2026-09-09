import 'package:json_annotation/json_annotation.dart';

part 'model_083.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model083 {
  const Model083({required this.id, required this.value});

  final int id;
  final String value;

  factory Model083.fromJson(Map<String, dynamic> json) =>
      _$Model083FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model083ToJson(this);
}
