import 'package:json_annotation/json_annotation.dart';

part 'model_318.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model318 {
  const Model318({required this.id, required this.value});

  final int id;
  final String value;

  factory Model318.fromJson(Map<String, dynamic> json) =>
      _$Model318FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model318ToJson(this);
}
